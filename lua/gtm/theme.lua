-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.theme: apply the reactive theme
--
-- gtmd owns the colours. It extracts a palette from the cover of the track on
-- air and pushes a resolved *role set* — `bg0`, `fg`, `accent`, and the rest —
-- over the pulse socket. This module picks the polarity and maps roles onto
-- highlight groups. It performs no colour arithmetic at all: a daemon without
-- role sets tints nothing, which beats this plugin guessing colours differently
-- from the TUI.
--
-- Two rules hold throughout: semantic groups (Error, Warning, Diff, Spell, Todo,
-- diagnostics, gitSigns) are never tinted, because an error that changes colour
-- with the artwork is worse than no error colour at all; and a group is only
-- written when its role is known, because leaving it at its colorscheme value
-- beats guessing.
--
-- This is free software released under the GPL-3.0 license.

local T = {}

T._enabled, T._touched, T._snap, T._extra = false, {}, nil, {}

-- Roles this module consumes. A daemon role set missing any of them is ignored
-- in favour of local derivation: a half-applied ramp is worse than a fallback.
local NEED = {
	"bg0", "bg1", "bg2", "bg3", "sel_bg",
	"fg", "fg_dim", "cursor_line_nr",
	"accent", "accent2", "accent3",
}

-- ============================================================================
-- Role -> highlight group. This mapping is data, and is the whole of what a
-- client has to own: group names are per-editor and cannot live in the daemon.
-- ============================================================================

local SURFACE = {
	Normal = "bg0", NormalNC = "bg0", TabLineFill = "bg0", LineNr = "bg0", SignColumn = "bg0",
	Pmenu = "bg1", StatusLineNC = "bg1", TabLine = "bg1", Folded = "bg1",
	StatusLine = "bg2", CursorLine = "bg2", CursorColumn = "bg2", ColorColumn = "bg2",
	Visual = "bg3", PmenuSel = "bg3", TabLineSel = "bg3",
	Search = "sel_bg", IncSearch = "sel_bg", CurSearch = "sel_bg",
}

-- Foreground overrides for groups that also take a surface.
local SURFACE_FG = {
	Search = "bg0", IncSearch = "bg0", CurSearch = "bg0",
	CursorLineNr = "cursor_line_nr", LineNr = "fg_dim", SignColumn = "fg_dim",
}

local DIM = { Comment = true, NonText = true, Whitespace = true, SpecialKey = true }

-- Syntax-tree base -> accent role (`@function.builtin.lua` -> `function.builtin`).
local SLOT = {
	["function.builtin"] = "accent", ["function.macro"] = "accent",
	keyword = "accent", type = "accent", identifier = "accent",
	string = "accent2", character = "accent2", constant = "accent2",
	comment = "accent3", punctuation = "accent3",
}

-- Prefix matching catches the spell and diagnostic variants.
local SEMANTIC = {
	Error = true, WarnMsg = true, MoreMsg = true, Question = true,
	Info = true, Hint = true, Todo = true, Diagnostic = true,
	Spell = true, Diff = true,
}

local function is_semantic(name)
	for prefix in pairs(SEMANTIC) do
		if name:sub(1, #prefix) == prefix then
			return true
		end
	end
	return name:sub(1, 8) == "gitSigns"
end

--- The foreground role a group takes.
local function fg_role(name)
	local slot = SLOT[name:gsub("^@", ""):gsub("[%w_]+$", "")]
	return SURFACE_FG[name] or (DIM[name] and "fg_dim") or (slot and SLOT[slot]) or "fg"
end

-- ============================================================================
-- Snapshot and restore
-- ============================================================================

--- Remember every global highlight group, so the tint can be undone exactly.
--- There is no API to enumerate highlight groups; `getcompletion(…, "highlight")`
--- is the documented way to get the list Neovim itself knows about.
function T.snapshot()
	local snap = {}
	for _, name in ipairs(vim.fn.getcompletion("", "highlight")) do
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
		if ok and type(hl) == "table" then
			snap[name] = hl
		end
	end
	T._snap = snap
end

function T.setup(opts)
	opts = opts or {}
	T._enabled, T._extra = opts.reactive == true, opts.extra_groups or {}
	T._touched, T._roles, T._sets, T._ver = {}, nil, nil, nil
	T.snapshot()
end

--- Whether reactive theming is on at all.
function T.enabled() return T._enabled end

--- Token-set version the daemon advertised.
function T.version() return T._ver end

--- The active role set (role -> 0xRRGGBB), or nil when nothing is tinted.
function T.roles() return T._roles end

--- Put every group the palette touched back to its snapshot value. The stored
--- role sets survive, so a colorscheme change can re-pick from them without
--- waiting for the next track.
function T.restore()
	for name in pairs(T._touched) do
		if T._snap and T._snap[name] then
			vim.api.nvim_set_hl(0, name, vim.deepcopy(T._snap[name]))
		end
	end
	T._touched, T._roles = {}, nil
end

--- Forget the role sets entirely, as `:Gtm theme reset` asks. Without this a
--- colorscheme change would resurrect a tint the user just turned off.
function T.clear()
	T.restore()
	T._sets, T._ver = nil, nil
end

-- ============================================================================
-- Applying a role set
-- ============================================================================

--- Apply resolved roles. The only path that writes highlights; both colour
--- sources funnel through it.
local function apply(roles)
	T._roles, T._touched = roles, {}
	for name, saved in pairs(T._snap or {}) do
		-- Linked groups resolve on their own; rewriting one would freeze the
		-- link into a literal.
		if type(saved) == "table" and not saved.link and not is_semantic(name) then
			local attrs = vim.deepcopy(saved)
			local bg = SURFACE[name]
			if bg then
				attrs.bg = roles[bg]
			end
			attrs.fg = roles[fg_role(name)]
			vim.api.nvim_set_hl(0, name, attrs)
			T._touched[name] = true
		end
	end
	for _, name in ipairs(T._extra) do
		vim.api.nvim_set_hl(0, name, { fg = roles.fg, bg = roles.bg1 })
		T._touched[name] = true
	end
end

-- ============================================================================
-- Source 1: roles from the daemon (preferred)
-- ============================================================================

local function from_hex(s)
	local h = type(s) == "string" and s:match("^#(%x%x%x%x%x%x)$")
	return h and { tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16) } or nil
end

--- {r,g,b} -> 0xRRGGBB, the form `nvim_set_hl` takes.
local function rgb_int(c)
	return c[1] * 65536 + c[2] * 256 + c[3]
end

--- Choose the polarity matching the editor's own background.
local function pick()
	local roles = T._sets and T._sets[vim.o.background == "light" and "light" or "dark"]
	if roles then
		apply(roles)
	end
end

--- Adopt a `reactive_theme` event. Both polarities are kept so a colorscheme
--- switch can re-pick without waiting for the next track. An incomplete set is
--- ignored outright rather than half-applied.
function T.set_roles(ev)
	if not T._enabled or type(ev) ~= "table" then
		return
	end
	local sets, complete = {}, true
	for _, polarity in ipairs({ "dark", "light" }) do
		local raw, roles = ev[polarity], {}
		if type(raw) ~= "table" then
			complete = false
			break
		end
		for _, role in ipairs(NEED) do
			local rgb = from_hex(raw[role])
			if not rgb then
				complete = false
				break
			end
			roles[role] = rgb_int(rgb)
		end
		sets[polarity] = roles
	end
	if complete then
		T._sets, T._ver = sets, ev.ver
		pick()
	end
end

--- The three accent colours behind the current tint, for `:Gtm theme`.
function T.palette_hexes()
	local function hx(n)
		return n and string.format("#%02x%02x%02x", math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) or "n/a"
	end
	local r = T._roles or {}
	return hx(r.accent), hx(r.accent2), hx(r.accent3)
end

--- The colorscheme changed. Put the tint down before re-snapshotting: the
--- semantic groups are now someone else's, and snapshotting while our own
--- colours are still applied would record the tint as the colorscheme's own and
--- make a later restore a no-op. Then re-apply against the new background.
function T.on_colorscheme()
	if not T._enabled or not T._sets then
		return
	end
	T.restore()
	T.snapshot()
	pick()
end

return T
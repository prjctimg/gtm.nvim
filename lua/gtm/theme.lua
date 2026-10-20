-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.theme: apply the reactive theme
--
-- gtmd owns the colours. It extracts a palette from the cover of the track on
-- air, resolves it into named *roles* — `accent`, `comment`, `sel_bg` and the
-- rest — and pushes a role set over the pulse socket. This module picks the
-- polarity and maps roles onto highlight groups.
--
-- One colour decision stays on the client: the background. The daemon cannot
-- know your colorscheme, so it cannot produce "your theme washed with the
-- album". Every background is therefore a wash of the daemon's `accent` over
-- the colour the group already had, scaled by `theme.intensity`. That is a
-- surface policy, not a second ramp: no role the daemon resolved is ever
-- re-derived here.
--
-- Two rules hold throughout: semantic groups (Error, Warning, Diff, Spell, Todo,
-- diagnostics, gitSigns) are never tinted, because an error that changes colour
-- with the artwork is worse than no error colour at all; and a group is only
-- written when its role is known, because leaving it at its colorscheme value
-- beats guessing.
--
-- This is free software released under the GPL-3.0 license.

local T = {}

T._enabled, T._applied, T._snap, T._extra = false, {}, nil, {}
T._base, T._intensity = nil, 0.25

-- Roles a set must carry before it is accepted at all: a half-applied ramp is
-- worse than none. Every other role is applied when the daemon sends it and
-- skipped when it does not, so a client built against a newer set degrades
-- instead of failing outright.
local NEED = {
	"bg0", "bg1", "bg2", "bg3", "sel_bg",
	"fg", "fg_dim", "cursor_line_nr",
	"accent", "accent2", "accent3",
}

-- ============================================================================
-- Role -> highlight group. The mapping is data, and is the whole of what a
-- client has to own: group names are per-editor and cannot live in the daemon.
-- ============================================================================

-- Foreground roles. A tree-sitter capture (`@function.builtin`) resolves through
-- its first segment, the base Vim group the capture mirrors.
local ROLE = {
	Comment = "comment",
	String = "string", Character = "string",
	Number = "number", Float = "number",
	Boolean = "boolean", Constant = "constant",
	Identifier = "identifier", Variable = "variable",
	Parameter = "variable", Field = "variable", Property = "variable",
	Function = "function", Constructor = "type",
	Statement = "keyword", Keyword = "keyword", Conditional = "keyword",
	Repeat = "keyword", Exception = "keyword", Label = "keyword",
	Include = "keyword", Define = "keyword", Macro = "keyword",
	PreProc = "keyword", PreCondit = "keyword",
	Operator = "operator",
	Type = "type", Structure = "type", Typedef = "type",
	StorageClass = "type", Namespace = "type", Module = "type",
	Special = "punctuation", SpecialChar = "punctuation",
	Delimiter = "punctuation", Punctuation = "punctuation",
	Title = "fg_bright", CursorLineNr = "cursor_line_nr",
	WinSeparator = "line", VertSplit = "line",
	LineNr = "fg_dim", SignColumn = "fg_dim",
	Visual = "sel_fg", PmenuSel = "sel_fg", TabLineSel = "sel_fg",
	Search = "search_fg", IncSearch = "search_fg", CurSearch = "search_fg",
}

-- Backgrounds the daemon resolves directly: selection, search and the cursor
-- line say something, so they take the daemon's role rather than the wash.
local BG = {
	Visual = "sel_bg", PmenuSel = "sel_bg", TabLineSel = "sel_bg",
	Search = "search_bg", IncSearch = "search_bg", CurSearch = "search_bg",
	CursorLine = "cursor_line", CursorColumn = "cursor_line", ColorColumn = "cursor_line",
	Cursor = "cursor",
}

local DIM = { NonText = true, Whitespace = true, SpecialKey = true }

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

--- The foreground role a group takes, or nil to leave its colorscheme value.
local function fg_role(name)
	if ROLE[name] then
		return ROLE[name]
	end
	local base = name:match("^@([%w_]+)")
	return (base and ROLE[base:sub(1, 1):upper() .. base:sub(2)]) or (DIM[name] and "fg_dim")
end

--- Blend two 0xRRGGBB colours. The only colour calculation in the client: the
--- background wash. It scales one step toward the accent and never re-resolves
--- a role the daemon already named.
local function wash(from, to, t)
	local function ch(c, shift) return math.floor(c / 2 ^ shift) % 256 end
	local function mix(a, b) return math.floor(a + (b - a) * t + 0.5) end
	return mix(ch(from, 16), ch(to, 16)) * 65536
		+ mix(ch(from, 8), ch(to, 8)) * 256
		+ mix(ch(from, 0), ch(to, 0))
end

-- ============================================================================
-- Snapshot and restore
-- ============================================================================

--- Remember every global highlight group, so the tint can be undone exactly.
--- There is no API to enumerate highlight groups; `getcompletion(…, "highlight")`
--- is the documented way to get the list Neovim itself knows about. The
--- colorscheme's own background is captured here too: the wash is applied to it,
--- not to a surface the daemon has never seen.
function T.snapshot()
	local snap = {}
	for _, name in ipairs(vim.fn.getcompletion("", "highlight")) do
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
		if ok and type(hl) == "table" then
			snap[name] = hl
		end
	end
	T._snap = snap
	local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
	T._base = normal.bg or (vim.o.background == "light" and 0xf6f4f1 or 0x0d0d12)
end

function T.setup(opts)
	opts = opts or {}
	T._enabled, T._extra = opts.reactive == true, opts.extra_groups or {}
	T._intensity = math.max(0, math.min(0.5, opts.intensity or 0.25))
	T._applied, T._roles, T._sets, T._ver = {}, nil, nil, nil
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
	for name in pairs(T._applied) do
		if T._snap and T._snap[name] then
			vim.api.nvim_set_hl(0, name, vim.deepcopy(T._snap[name]))
		end
	end
	T._applied, T._roles = {}, nil
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

--- Apply resolved roles. The only path that writes highlights.
local function apply(roles)
	T._roles, T._applied = roles, {}
	local accent = roles.accent
	local base = T._base or 0x0d0d12
	for name, saved in pairs(T._snap or {}) do
		-- Linked groups resolve on their own; rewriting one would freeze the
		-- link into a literal.
		if type(saved) == "table" and not saved.link and not is_semantic(name) then
			local attrs, changed = vim.deepcopy(saved), false
			local bg = BG[name] and roles[BG[name]]
			if bg then
				attrs.bg, changed = bg, true
			elseif accent then
				-- Wash the group's own colour, so the colorscheme's elevation
				-- survives and only the hue is ours. Normal may have no
				-- background yet; the captured base stands in for it.
				local from = saved.bg or ((name == "Normal" or name == "NormalNC") and base)
				if from then
					attrs.bg, changed = wash(from, accent, T._intensity), true
				end
			end
			local role = fg_role(name)
			local fg = role and roles[role]
			if fg then
				attrs.fg, changed = fg, true
			end
			if changed then
				vim.api.nvim_set_hl(0, name, attrs)
				-- Keep what we wrote: a colorscheme change has to tell our own
				-- writes apart from groups the new scheme redefined itself.
				T._applied[name] = attrs
			end
		end
	end
	for _, name in ipairs(T._extra) do
		local attrs = { fg = roles.fg, bg = accent and wash(base, accent, T._intensity) }
		vim.api.nvim_set_hl(0, name, attrs)
		T._applied[name] = attrs
	end
end

-- ============================================================================
-- Roles from the daemon
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
			if not from_hex(raw[role]) then
				complete = false
				break
			end
		end
		if not complete then
			break
		end
		-- Every role the daemon resolved, not just the required ones: the
		-- syntax roles are what keep code legible under the tint.
		for role, hex in pairs(raw) do
			local rgb = from_hex(hex)
			if rgb then
				roles[role] = rgb_int(rgb)
			end
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

--- The colorscheme changed. The new scheme has already re-applied its own
--- highlights, so ours survived only where it did not define the group. Put our
--- own writes back to their pre-tint baseline *only where they are still ours*:
--- restoring the previous scheme's colours over the new one would be worse than
--- leaving the tint, and snapshotting our own tint would record it as pristine
--- and turn a later restore into a no-op. Then re-snapshot and re-apply against
--- the new background.
---
--- Deferred with `vim.schedule`: colorscheme plugins register their own
--- `ColorScheme` handlers and whichever runs last wins, so ours has to run after
--- all of them to keep top precedence over the tint.
function T.on_colorscheme()
	if not T._enabled then
		return
	end
	vim.schedule(function()
		if not T._enabled then
			return
		end
		for name, attrs in pairs(T._applied) do
			local current = vim.api.nvim_get_hl(0, { name = name, link = false })
			if T._snap and T._snap[name] and vim.deep_equal(attrs, current) then
				vim.api.nvim_set_hl(0, name, vim.deepcopy(T._snap[name]))
			end
		end
		T._applied, T._roles = {}, nil
		T.snapshot()
		if T._sets then
			pick()
		end
	end)
end

--- Re-assert the current tint. A safety net for a background some other actor
--- overwrote without a `ColorScheme` of its own firing; the pulse stream is
--- still the source of truth for *what* the colours are.
function T.refresh()
	if T._enabled and T._sets then
		pick()
	end
end

return T

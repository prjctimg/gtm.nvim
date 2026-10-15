-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.theme: apply the reactive theme
--
-- gtmd owns the colours. It extracts a palette from the cover of the track on
-- air and pushes a resolved *role set* — `bg0`, `fg`, `accent`, and the rest —
-- over the pulse socket. This module holds no arithmetic in the normal path: it
-- picks the polarity and maps roles onto highlight groups.
--
-- Local derivation below is a fallback for daemons older than the role-set
-- event, which send only `reactive_palette` (three colours). It emits the same
-- role names, so `apply` has a single path either way. Delete it once the
-- daemon release carrying role sets is widely deployed.
--
-- Two rules hold throughout:
--
--   * Meaningful colours stay put. Error, warning, diff, spell and `Todo` groups
--     are never tinted — an error that changes colour with the artwork is worse
--     than no error colour at all.
--   * A group is only written when its role is known. Leaving an unrecognised
--     group at its colorscheme value beats guessing.
--
-- This is free software released under the GPL-3.0 license.

local T = {}

T._enabled, T._touched, T._snap, T._extra = false, {}, nil, {}

-- Roles this module consumes. A daemon role set missing any of them is ignored
-- in favour of local derivation, so an older daemon can never half-tint.
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

--- The foreground role a group takes.
local function fg_role(name)
	local slot = SLOT[name:gsub("^@", ""):gsub("[%w_]+$", "")]
	return SURFACE_FG[name] or (DIM[name] and "fg_dim") or (slot and SLOT[slot]) or "fg"
end

-- Groups that carry meaning rather than decoration. Prefix matching catches the
-- spell and diagnostic variants.
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
	T._touched = {}
	T._snap, T._roles, T._sets, T._ver = nil, nil, nil, nil
	T._src, T._pal = nil, nil
	T.snapshot()
end

function T.enabled()
	return T._enabled
end

--- Where the active colours came from: `"daemon"`, `"local"`, or nil.
function T.source()
	return T._src
end

--- Token-set version the daemon advertised, or nil when deriving locally.
function T.version()
	return T._ver
end

--- The active role set (role -> 0xRRGGBB), or nil when nothing is tinted.
function T.roles()
	return T._roles
end

--- Put every group the palette touched back to its snapshot value.
function T.restore()
	for name in pairs(T._touched) do
		if T._snap and T._snap[name] then
			vim.api.nvim_set_hl(0, name, vim.deepcopy(T._snap[name]))
		end
	end
	T._touched, T._roles, T._src, T._pal = {}, nil, nil, nil
end

T.clear = T.restore

-- ============================================================================
-- Applying a role set
-- ============================================================================

--- Apply resolved roles. This is the only path that writes highlights; both
--- colour sources funnel through it.
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

--- "#rrggbb" -> 0xRRGGBB, or nil if that is not one.
local function as_int(hex)
	local h = type(hex) == "string" and hex:match("^#(%x%x%x%x%x%x)$")
	return h and (tonumber(h:sub(1, 2), 16) * 65536 + tonumber(h:sub(3, 4), 16) * 256 + tonumber(h:sub(5, 6), 16)) or nil
end

--- Adopt a `reactive_theme` event. Both polarities are kept so a colorscheme
--- switch can re-pick without waiting for the next track.
function T.set_roles(ev)
	if not T._enabled or type(ev) ~= "table" then
		return
	end
	local sets, complete = {}, true
	for _, polarity in ipairs({ "dark", "light" }) do
		local raw = ev[polarity]
		if type(raw) ~= "table" then
			complete = false
			break
		end
		local roles = {}
		for _, role in ipairs(NEED) do
			roles[role] = as_int(raw[role])
			if not roles[role] then
				complete = false
				break
			end
		end
		sets[polarity] = roles
	end
	if not complete then
		-- An older or partial role set is ignored outright; a half-applied ramp
		-- is worse than the local derivation.
		return
	end
	T._sets, T._ver = sets, ev.ver
	T._pick()
end

--- Choose the polarity matching the editor's own background.
function T._pick()
	if not T._sets then
		return
	end
	local roles = T._sets[vim.o.background == "light" and "light" or "dark"]
	if not roles then
		return
	end
	T._src = "daemon"
	apply(roles)
end

-- ============================================================================
-- Source 2: local derivation (fallback for daemons without role sets)
-- ============================================================================

local function luminance(c)
	return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end

local function hsv_to_rgb(h, s, v)
	h = h % 360
	if h < 0 then
		h = h + 360
	end
	local c = v * s
	local x = c * (1 - math.abs((h / 60) % 2 - 1))
	local m = v - c
	local r, g, b
	if h < 60 then
		r, g, b = c, x, 0
	elseif h < 120 then
		r, g, b = x, c, 0
	elseif h < 180 then
		r, g, b = 0, c, x
	elseif h < 240 then
		r, g, b = 0, x, c
	elseif h < 300 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end
	return {
		math.floor((r + m) * 255 + 0.5),
		math.floor((g + m) * 255 + 0.5),
		math.floor((b + m) * 255 + 0.5),
	}
end

local function rgb_to_hsv(c)
	local r, g, b = c[1] / 255, c[2] / 255, c[3] / 255
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local d = max - min
	if d <= 0 then
		return 0, 0, max
	end
	local h = max == r and ((g - b) / d) % 6 or (max == g and (b - r) / d + 2 or (r - g) / d + 4)
	return h * 60, d / max, max
end

local function mix(a, b, t)
	return {
		math.floor(a[1] * (1 - t) + b[1] * t + 0.5),
		math.floor(a[2] * (1 - t) + b[2] * t + 0.5),
		math.floor(a[3] * (1 - t) + b[3] * t + 0.5),
	}
end

--- Nudge a colour toward white or black so it reads as an accent on the current
--- polarity. Bounded: an unbounded correction to a target luminance turns a
--- vivid album colour into a pastel.
local function adjust(c, light)
	local l, target = luminance(c), light and 70 or 170
	if math.abs(l - target) < 40 then
		return c
	end
	local t = math.max(-0.35, math.min(0.35, (target - l) / 255))
	return t >= 0 and mix(c, { 255, 255, 255 }, t) or mix(c, { 0, 0, 0 }, -t)
end

--- Build the same role names from three album colours. Mirrors the daemon's
--- `derive(pal, dark)` so both sources are interchangeable.
local function derive(pal, light)
	local h, s = rgb_to_hsv(pal.primary)
	local int = function(c)
		return c[1] * 65536 + c[2] * 256 + c[3]
	end

	-- The album hue drives every surface; only the saturation and the four
	-- lightness steps differ between polarities.
	local sat = light and s * 0.25 or s * 0.45
	local bg = {}
	for i, v in ipairs(light and { 0.975, 0.945, 0.910, 0.850 } or { 0.060, 0.090, 0.120, 0.170 }) do
		bg[i] = int(hsv_to_rgb(h, sat, v))
	end

	local accent = int(adjust(pal.primary, light))
	local fs = light and s * 0.15 or s * 0.12

	return {
		bg0 = bg[1], bg1 = bg[2], bg2 = bg[3], bg3 = bg[4],
		sel_bg = int(mix(hsv_to_rgb(h, sat, light and 0.975 or 0.060), pal.primary, 0.30)),
		fg = int(hsv_to_rgb(h, fs, light and 0.16 or 0.90)),
		fg_dim = int(hsv_to_rgb(h, fs, light and 0.44 or 0.60)),
		accent = accent,
		accent2 = int(adjust(pal.secondary, light)),
		accent3 = int(adjust(pal.tertiary, light)),
		cursor_line_nr = accent,
	}
end

--- "#rrggbb" for one channel triple, the form the palette crosses the wire in.
local function from_hex(s)
	local h = type(s) == "string" and s:match("^#(%x%x%x%x%x%x)$")
	return h and { tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16) } or nil
end

--- Palette from a `reactive_palette` event, or nil if any channel is missing.
--- The fallback path only: three empty strings mean the daemon had no art.
function T.apply(ev)
	if not T._enabled or type(ev) ~= "table" then
		return
	end
	local p, s, t = from_hex(ev.primary), from_hex(ev.secondary), from_hex(ev.tertiary)
	if not (p and s and t) then
		return T.restore()
	end
	T._src, T._pal = "local", { primary = p, secondary = s, tertiary = t }
	apply(derive(T._pal, vim.o.background ~= "light"))
end

--- The three colours behind the current tint, for `:Gtm theme`.
function T.palette_hexes()
	local roles = T._roles
	if not roles then
		return { primary = "n/a", secondary = "n/a", tertiary = "n/a" }
	end
	local function hx(n)
		return string.format("#%02x%02x%02x", math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
	end
	return { primary = hx(roles.accent), secondary = hx(roles.accent2), tertiary = hx(roles.accent3) }
end

--- The colorscheme changed. Put the tint down before re-snapshotting: the
--- semantic groups are now someone else's, and snapshotting while our own
--- colours are still applied would record the tint as the colorscheme's own and
--- make a later restore a no-op. Then re-apply: a daemon role set just re-picks
--- its polarity, a local one re-derives against the new background.
function T.on_colorscheme()
	if not T._enabled or not T._src then
		return
	end
	local src, sets, pal = T._src, T._sets, T._pal
	T.restore()
	T.snapshot()
	if src == "daemon" and sets then
		T._pick()
	elseif src == "local" and pal then
		apply(derive(pal, vim.o.background ~= "light"))
	end
end

return T
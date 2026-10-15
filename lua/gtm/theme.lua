-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.theme: derive the editor colorscheme from the album palette
--
-- gtmd extracts the palette from the cover of the track on air and broadcasts a
-- `reactive_palette` event; this module never decodes an image. It builds a
-- whole highlight ramp from those three colours, swaps it into the editor, and
-- restores the previous values when playback stops.
--
-- Two rules hold throughout:
--
--   * Surfaces are built, never blended. Every background is computed from the
--     album hue, so `Normal` really is the album's colour and switching
--     colorscheme cannot silently change the result.
--   * Meaningful colours stay put. Error, warning, diff, spell and `Todo` groups
--     are never tinted — an error that changes colour with the artwork is worse
--     than no error colour at all.
--
-- This is free software released under the GPL-3.0 license.

local T = {}

T._enabled, T._touched, T._snap, T._palette, T._extra = false, {}, nil, nil, {}

-- ============================================================================
-- Colour maths
-- ============================================================================

--- "#rrggbb" -> {r,g,b}. The wire form: an empty or malformed field means "no
--- art", not "black".
function T.from_hex(s)
	local h = type(s) == "string" and s:match("^#(%x%x%x%x%x%x)$")
	return h and { tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16) } or nil
end

--- Palette from a `reactive_palette` event, or nil if any channel is missing.
function T.palette_from(ev)
	if type(ev) ~= "table" then
		return nil
	end
	local p, s, t = T.from_hex(ev.primary), T.from_hex(ev.secondary), T.from_hex(ev.tertiary)
	return (p and s and t) and { primary = p, secondary = s, tertiary = t } or nil
end

local function luminance(c)
	return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end

local function hsv_to_rgb(h, s, v)
	h = h % 360
	if h < 0 then
		h = h + 360
	end
	local c, x, m = v * s, 0, 0
	x = c * (1 - math.abs((h / 60) % 2 - 1))
	m = v - c
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

--- {r,g,b} -> 0xRRGGBB, the form `nvim_set_hl` takes.
local function as_int(c)
	return c[1] * 65536 + c[2] * 256 + c[3]
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

-- ============================================================================
-- Which groups may be touched
-- ============================================================================

-- Groups that carry meaning rather than decoration. Prefix matching catches
-- the spell and diagnostic variants.
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

--- Which accent slot a group takes, by name, comparing against the dotted
--- syntax-tree base (`@function.builtin.lua` -> `function.builtin`). nil means
--- it takes the plain ramp foreground instead.
local SLOTS = {
	["function.builtin"] = "primary", ["function.macro"] = "primary",
	keyword = "primary", type = "primary", identifier = "primary",
	string = "secondary", character = "secondary", constant = "secondary",
	comment = "tertiary", punctuation = "tertiary",
}

local function role_for(name)
	return SLOTS[name:gsub("^@", ""):gsub("[%w_]+$", "")]
end

-- Background each group takes from the ramp; 5 is the selection blend.
local BG = {
	Normal = 1, NormalNC = 1, TabLineFill = 1, LineNr = 1, SignColumn = 1,
	Pmenu = 2, StatusLineNC = 2, TabLine = 2, Folded = 2,
	StatusLine = 3, CursorLine = 3, CursorColumn = 3, ColorColumn = 3, CursorLineNr = 3,
	Visual = 4, PmenuSel = 4, TabLineSel = 4,
	Search = 5, IncSearch = 5, CurSearch = 5,
}

local DIM = { Comment = true, NonText = true, Whitespace = true, SpecialKey = true, LineNr = true, SignColumn = true }

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
	T._touched, T._palette = {}, nil
	T.snapshot()
end

function T.enabled()
	return T._enabled
end

function T.palette()
	return T._palette
end

--- Put every group the palette touched back to its snapshot value.
function T.restore()
	for name in pairs(T._touched) do
		if T._snap and T._snap[name] then
			vim.api.nvim_set_hl(0, name, vim.deepcopy(T._snap[name]))
		end
	end
	T._touched, T._palette = {}, nil
end

T.clear = T.restore

-- ============================================================================
-- Derivation
-- ============================================================================

--- Everything the highlight pass needs, from the three album colours alone.
--- Nothing here reads the colorscheme, which is what makes the result
--- independent of it. Colours leave as 0xRRGGBB integers because that is what
--- `nvim_set_hl` wants.
local function derive_ctx(pal)
	local h, s = rgb_to_hsv(pal.primary)
	local light = luminance(pal.primary) > 140

	-- The album hue drives every surface; only the saturation and the four
	-- lightness steps differ between polarities.
	local sat = light and s * 0.25 or s * 0.45
	local bg = {}
	for i, v in ipairs(light and { 0.975, 0.945, 0.910, 0.850 } or { 0.060, 0.090, 0.120, 0.170 }) do
		bg[i] = as_int(hsv_to_rgb(h, sat, v))
	end

	local accent = {
		primary = adjust(pal.primary, light),
		secondary = adjust(pal.secondary, light),
		tertiary = adjust(pal.tertiary, light),
	}
	local fs = light and s * 0.15 or s * 0.12

	-- `sel` has to mix against the *unrounded* base surface, so it is derived
	-- before the ramp is packed.
	local sel = mix(hsv_to_rgb(h, sat, light and 0.975 or 0.060), accent.primary, 0.30)

	return {
		accent = {
			primary = as_int(accent.primary),
			secondary = as_int(accent.secondary),
			tertiary = as_int(accent.tertiary),
		},
		bg = bg,
		fg = as_int(hsv_to_rgb(h, fs, light and 0.16 or 0.90)),
		fg_dim = as_int(hsv_to_rgb(h, fs, light and 0.44 or 0.60)),
		sel = as_int(sel),
	}
end

--- Apply a palette. A group is only written when this module knows what it
--- should be: leaving an unrecognised group at its colorscheme value beats
--- guessing, and it is why one palette yields identical surfaces under two
--- different colorschemes.
function T.apply(pal)
	if not pal then
		return
	end
	local ctx = derive_ctx(pal)
	local ramp = { ctx.bg[1], ctx.bg[2], ctx.bg[3], ctx.bg[4], ctx.sel }
	T._palette, T._touched = pal, {}

	for name, saved in pairs(T._snap or {}) do
		-- Linked groups resolve on their own; rewriting one would freeze the
		-- link into a literal.
		if type(saved) == "table" and not saved.link and not is_semantic(name) then
			local attrs, bg = vim.deepcopy(saved), BG[name]
			if bg then
				attrs.bg = ramp[bg]
				attrs.fg = bg == 5 and ctx.bg[1]
					or name == "CursorLineNr" and ctx.accent.primary
					or DIM[name] and ctx.fg_dim
					or ctx.fg
			else
				local slot = role_for(name)
				attrs.fg = slot and ctx.accent[slot] or DIM[name] and ctx.fg_dim or ctx.fg
			end
			vim.api.nvim_set_hl(0, name, attrs)
			T._touched[name] = true
		end
	end

	for _, name in ipairs(T._extra) do
		vim.api.nvim_set_hl(0, name, { fg = ctx.fg, bg = ctx.bg[2] })
		T._touched[name] = true
	end
end

--- Hex strings for `:Gtm theme`.
function T.palette_hexes(pal)
	local out = {}
	for _, key in ipairs({ "primary", "secondary", "tertiary" }) do
		local c = pal[key]
		out[key] = c and string.format("#%02x%02x%02x", c[1], c[2], c[3]) or "n/a"
	end
	return out
end

--- The colorscheme changed: the semantic groups are now someone else's, so
--- re-snapshot them and re-apply the palette we are already holding. The tint
--- survives a theme swap instead of quietly disappearing.
function T.on_colorscheme()
	if not T._enabled then
		return
	end
	local pal = T._palette
	T.snapshot()
	if pal then
		T.apply(pal)
	end
end

return T
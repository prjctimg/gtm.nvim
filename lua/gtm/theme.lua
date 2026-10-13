-- Copyright (c) 2026
-- Author: prjctimg <prjctimg@outlook.com>
-- Reactive theme: derive the editor colorscheme from the album palette
--
-- This is free software released under the GPL-3.0 license.

--! ## Where the palette comes from
--!
--! gtmd extracts it from the cover of the track on air and broadcasts a
--! `reactive_palette` event; this module never decodes an image. The editor
--! colorscheme is snapshotted for two things only: restoring, and the semantic
--! groups that carry meaning rather than decoration.
--!
--! ## Why the surfaces are built rather than blended
--!
--! Blending the palette into the colorscheme makes every surface a function of
--! both, so `Normal` is never the album's colour and switching colorschemes
--! changes the result. Here the album hue drives the whole ramp and the
--! colourscheme contributes nothing but the semantic groups.

local T = {}

-- ============================================================================
-- Colour maths
-- ============================================================================

--- 24-bit int -> {r,g,b}.
local function to_rgb(v)
	if type(v) == "number" then
		return { math.floor(v / 65536), math.floor(v / 256) % 256, v % 256 }
	end
	return { 30, 30, 30 }
end

--- "#rrggbb" -> {r,g,b}, or nil. The wire form: three hex strings, empty
--- meaning "no art".
function T.from_hex(s)
	if type(s) ~= "string" then
		return nil
	end
	local h = s:match("^#(%x%x%x%x%x%x)$")
	if not h then
		return nil
	end
	return {
		tonumber(h:sub(1, 2), 16),
		tonumber(h:sub(3, 4), 16),
		tonumber(h:sub(5, 6), 16),
	}
end

--- Build a palette from the event's three fields, or nil if any is missing.
function T.pal_from(ev)
	if type(ev) ~= "table" then
		return nil
	end
	local p, s, t = T.from_hex(ev.primary), T.from_hex(ev.secondary), T.from_hex(ev.tertiary)
	if not (p and s and t) then
		return nil
	end
	return { primary = p, secondary = s, tertiary = t }
end

local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
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
	local h = 0
	if d > 0 then
		if math.abs(max - r) < 1e-9 then
			h = ((g - b) / d) % 6
		elseif math.abs(max - g) < 1e-9 then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h * 60
	end
	local s = max <= 0 and 0 or d / max
	return h, s, max
end

local function luminance(c)
	return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end

--- Linear blend of two {r,g,b}.
local function mix(a, b, t)
	return {
		math.floor(a[1] * (1 - t) + b[1] * t + 0.5),
		math.floor(a[2] * (1 - t) + b[2] * t + 0.5),
		math.floor(a[3] * (1 - t) + b[3] * t + 0.5),
	}
end

--- Nudge a colour toward white or black so it is readable as an accent on the
--- current polarity. Bounded, because an unbounded correction to a target
--- luminance turns a vivid album colour into a pastel.
local function adjust(c, light)
	local l = luminance(c)
	local target = light and 70 or 170
	if math.abs(l - target) < 40 then
		return c
	end
	local t = clamp((target - l) / 255, -0.35, 0.35)
	if t >= 0 then
		return mix(c, { 255, 255, 255 }, t)
	end
	return mix(c, { 0, 0, 0 }, -t)
end

-- ============================================================================
-- Highlight group management
-- ============================================================================

local function set_hl(name, attrs)
	vim.api.nvim_set_hl(0, name, attrs)
end

--- Semantic families keep their colorscheme colours: they encode meaning, and
--- an error that changes colour with the album is worse than no error colour.
local SEMANTIC = {
	Error = true,
	WarnMsg = true,
	MoreMsg = true,
	Question = true,
	Info = true,
	Hint = true,
	Todo = true,
	DiagnosticError = true,
	DiagnosticWarn = true,
	DiagnosticInfo = true,
	DiagnosticHint = true,
	DiagnosticOk = true,
	SpellBad = true,
	SpellCap = true,
	SpellLocal = true,
	SpellRare = true,
	DiffAdd = true,
	DiffChange = true,
	DiffDelete = true,
	DiffText = true,
	DiffRemoved = true,
}

local function is_semantic(name)
	if SEMANTIC[name] then
		return true
	end
	for prefix in pairs(SEMANTIC) do
		if name:sub(1, #prefix) == prefix then
			return true
		end
	end
	return name:match("^gitSigns") ~= nil
end

--- Which accent slot a group takes, by name. `nil` means it takes the ramp's
--- foreground rather than an accent.
local function role_for(name)
	local base = name:gsub("^@", ""):gsub("[%w_]+$", "")
	if
		base == "function.builtin"
		or base == "function.macro"
		or base == "keyword"
		or base == "type"
		or base == "identifier"
	then
		return "primary"
	elseif base == "string" or base == "character" or base == "constant" then
		return "secondary"
	elseif base == "comment" or base == "punctuation" then
		return "tertiary"
	end
	return nil
end

-- ============================================================================
-- Snapshot and restore
-- ============================================================================

--- Snapshot every global highlight group.
function T.snapshot()
	local groups = vim.api.nvim_get_names()
	local snap = {}
	for _, name in ipairs(groups) do
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
		if ok and type(hl) == "table" then
			snap[name] = hl
		end
	end
	T._snap = snap
	return snap
end

--- Put every group the palette touched back to its snapshot value.
function T.restore()
	if not T._snap then
		return
	end
	for name in pairs(T._touched or {}) do
		local saved = T._snap[name]
		if saved then
			set_hl(name, vim.deepcopy(saved))
		end
	end
	T._touched = {}
	T._palette = nil
	T._ctx = nil
end

function T.is_active()
	return T._palette ~= nil
end

function T.is_enabled()
	return not (T._opts and T._opts.reactive == false)
end

function T.current_palette()
	return T._palette
end

function T.setup(opts)
	T._opts = opts or {}
	T._touched = {}
	T._palette = nil
	T.snapshot()
end

-- ============================================================================
-- Derivation
-- ============================================================================

--- Everything the highlight pass needs, from the three album colours alone.
local function derive_ctx(pal)
	local h, s = rgb_to_hsv(pal.primary)
	local light = luminance(pal.primary) > 140

	-- The album hue drives every surface; only the saturation and the four
	-- lightness steps differ between polarities. Nothing here reads the
	-- colorscheme, which is what makes the result independent of it.
	local sat = light and s * 0.25 or s * 0.45
	local bg = {}
	if light then
		bg = { hsv_to_rgb(h, sat, 0.975), hsv_to_rgb(h, sat, 0.945), hsv_to_rgb(h, sat, 0.910), hsv_to_rgb(h, sat, 0.850) }
	else
		bg = { hsv_to_rgb(h, sat, 0.060), hsv_to_rgb(h, sat, 0.090), hsv_to_rgb(h, sat, 0.120), hsv_to_rgb(h, sat, 0.170) }
	end

	local accent = {
		primary = adjust(pal.primary, light),
		secondary = adjust(pal.secondary, light),
		tertiary = adjust(pal.tertiary, light),
	}
	local fs = light and s * 0.15 or s * 0.12
	local fg = hsv_to_rgb(h, fs, light and 0.16 or 0.90)
	local fg_dim = hsv_to_rgb(h, fs, light and 0.44 or 0.60)

	return {
		light = light,
		hue = h,
		bg = bg,
		fg = fg,
		fg_dim = fg_dim,
		accent = accent,
		sel = mix(bg[1], accent.primary, 0.30),
		line = mix(bg[1], accent.primary, 0.18),
		slots = accent,
	}
end

--- The float's own groups. `bg[1]` is the ramp's darkest surface, which is
--- what the float sits on.
local function float_groups(ctx)
	local a = ctx.accent
	return {
		NormalFloat = { fg = ctx.fg, bg = ctx.bg[2] },
		FloatBorder = { fg = ctx.line, bg = ctx.bg[2] },
		WinSeparator = { fg = ctx.line },
		VertSplit = { fg = ctx.line },
		FloatTitle = { fg = a.primary, bg = ctx.bg[2], bold = true },
		FloatFooter = { fg = ctx.fg_dim, bg = ctx.bg[2] },
		GtmIcon = { fg = a.primary, bg = ctx.bg[2] },
		GtmBar = { fg = a.primary, bg = ctx.bg[2] },
		GtmTitle = { fg = ctx.fg, bg = ctx.bg[2] },
		GtmArtist = { fg = a.secondary, bg = ctx.bg[2] },
		GtmTime = { fg = a.secondary, bg = ctx.bg[2] },
		GtmAlbum = { fg = a.tertiary, bg = ctx.bg[2] },
		GtmBarEmpty = { fg = ctx.fg_dim, bg = ctx.bg[2] },
		GtmVolume = { fg = ctx.fg_dim, bg = ctx.bg[2] },
		GtmHint = { fg = ctx.fg_dim, bg = ctx.bg[2] },
	}
end

--- Apply a palette: write an explicit value for every non-semantic group.
---
--- A group is only written when this module knows what it should be. Leaving an
--- unrecognised group at its colorscheme value is better than guessing, and it
--- is why the same palette under two colorschemes yields the same surfaces —
--- every surface here is computed, none of it inherited.
function T.apply(pal)
	if not pal then
		return
	end
	local ctx = derive_ctx(pal)
	T._palette = pal
	T._ctx = ctx
	T._touched = {}

	if (T._opts.scope or "global") == "global" then
		for name, saved in pairs(T._snap or {}) do
			if type(saved) ~= "table" or saved.link or is_semantic(name) then
				goto continue
			end
			local attrs = vim.deepcopy(saved)
			local slot = role_for(name)
			-- Background-bearing chrome follows the ramp by name; everything
			-- else takes the ramp foreground or its accent slot.
			if name == "Normal" or name == "NormalNC" or name == "TabLineFill" then
				attrs.bg = ctx.bg[1]
				attrs.fg = ctx.fg
			elseif name == "CursorLine" or name == "CursorColumn" or name == "ColorColumn" then
				attrs.bg = ctx.bg[3]
			elseif name == "Visual" then
				attrs.bg = ctx.bg[4]
			elseif name == "Search" or name == "IncSearch" or name == "CurSearch" then
				attrs.bg = ctx.sel
				attrs.fg = ctx.bg[1]
			elseif name == "Pmenu" or name == "StatusLineNC" or name == "TabLine" or name == "Folded" then
				attrs.bg = ctx.bg[2]
				attrs.fg = ctx.fg
			elseif name == "PmenuSel" or name == "TabLineSel" then
				attrs.bg = ctx.bg[4]
				attrs.fg = ctx.fg
			elseif name == "StatusLine" then
				attrs.bg = ctx.bg[3]
				attrs.fg = ctx.fg
			elseif name == "LineNr" or name == "SignColumn" then
				attrs.bg = ctx.bg[1]
				attrs.fg = ctx.fg_dim
			elseif name == "CursorLineNr" then
				attrs.bg = ctx.bg[3]
				attrs.fg = ctx.accent.primary
			elseif
				name == "Comment"
				or name == "NonText"
				or name == "Whitespace"
				or name == "SpecialKey"
			then
				attrs.fg = ctx.fg_dim
			elseif slot then
				attrs.fg = ctx.accent[slot]
			else
				attrs.fg = ctx.fg
			end
			set_hl(name, attrs)
			T._touched[name] = true
			::continue::
		end
	end

	local derived = float_groups(ctx)
	T._derived = derived
	for name, attrs in pairs(derived) do
		set_hl(name, attrs)
		T._touched[name] = true
	end
	for _, name in ipairs(T._opts.extra_groups or {}) do
		set_hl(name, { fg = ctx.fg, bg = ctx.bg[2] })
		T._touched[name] = true
	end
end

--- Remove the tint.
function T.clear()
	T.restore()
end

--- Hex strings for the `:Gtm theme` status command.
function T.palette_hexes(pal)
	local function hx(c)
		if not c then
			return "n/a"
		end
		return string.format("#%02x%02x%02x", c[1], c[2], c[3])
	end
	return { hx(pal.primary), hx(pal.secondary), hx(pal.tertiary) }
end

--- The colorscheme changed: the semantic groups are now someone else's, so
--- re-snapshot them and re-apply the palette we are already holding.
function T.on_colorscheme()
	T.snapshot()
	if T._palette and T.is_enabled() then
		T.apply(T._palette)
	end
end

return T
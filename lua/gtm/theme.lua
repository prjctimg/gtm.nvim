-- Copyright (c) 2025 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.theme: reactive, cover-derived highlight groups
--
-- When `theme.reactive` is enabled and a track with artwork is playing, the
-- album art's dominant colors tint **global** highlight groups: the float
-- surface takes a faint wash of the dominant color (`intensity`), while
-- accents (title, progress bar, border) take the palette's primary/secondary/
-- tertiary colors nearly verbatim — a faithful port of the daemon's own
-- reactive pass in `gtm/src/reactive.rs` (extract_palette + derive_theme).
--
-- Palette pipeline mirrors the daemon:
--
--   extract()   downscale the cover to 24x24 raw RGB via ffmpeg / ImageMagick
--   quantize()  5-bit histogram -> top-10 dominant colors (color-thief stand-in)
--   select()    primary + hue-furthest secondary + tertiary (sat > 0.12 gate)
--   derive()    blend the palette into the colorscheme's float groups
--
-- Lifecycle: the tint is applied on track change and **kept while paused**,
-- restored on stop / track change / close. Setup defines the `Gtm*` groups
-- (used by the float's per-line highlights) as links, re-snapshots on
-- `ColorScheme`, and re-derives if a palette is active. Everything mutates
-- global groups by design (user preference); restore is exact via
-- `nvim_get_hl {link=true}` round-trip.
--
-- This is free software released under the GPL-3.0 license.

local T = {}

-- Groups the reactive pass may override. The Gtm* groups are defined at setup
-- (links into colorscheme anchors) and consumed by the float highlights.
local FLOAT_GROUPS = { "NormalFloat", "FloatBorder", "FloatTitle", "FloatFooter" }

local GTM_GROUPS = {
	"GtmIcon",
	"GtmTitle",
	"GtmArtist",
	"GtmAlbum",
	"GtmTime",
	"GtmBar",
	"GtmBarEmpty",
	"GtmVolume",
	"GtmHint",
}

-- Initial definitions: everything is a link so no palette is hard-coded and
-- the reactive pass overrides per-line via explicit attrs.
local BASE_LINKS = {
	GtmIcon = "Special",
	GtmTitle = "Title",
	GtmArtist = "String",
	GtmAlbum = "Comment",
	GtmTime = "Number",
	GtmBar = "Constant",
	GtmBarEmpty = "Comment",
	GtmVolume = "Number",
	GtmHint = "Comment",
}

local WHITE = { 255, 255, 255 }
local BLACK = { 0, 0, 0 }

T._opts = { reactive = false, intensity = 0.2, extra_groups = {} }
T._snap = {}
T._base = nil
T._palette = nil
T._derived = nil

-- ============================================================================
-- Color math (ports of gtm/src/reactive.rs)
-- ============================================================================

local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
end

local function luminance(c)
	return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end

local function rgb_to_hsv(c)
	local r, g, b = c[1] / 255, c[2] / 255, c[3] / 255
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local d = max - min
	local h = 0
	if d > 0 then
		if math.abs(max - r) < 1e-6 then
			h = ((g - b) / d) % 6
		elseif math.abs(max - g) < 1e-6 then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h * 60
	end
	local s = max <= 0 and 0 or d / max
	return h, s, max
end

local function hsv_to_rgb(h, s, v)
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
	return math.floor((r + m) * 255), math.floor((g + m) * 255), math.floor((b + m) * 255)
end

--- Circular hue distance in degrees, range [0, 180].
local function hue_distance(a, b)
	local d = math.abs(a - b) % 360
	if d > 180 then
		return 360 - d
	end
	return d
end

local function hue_shift(c, turns)
	local h, s, v = rgb_to_hsv(c)
	return hsv_to_rgb((h + 360 * turns) % 360, math.max(s, 0.25), math.min(v * 1.15, 1))
end

local function blend(c1, c2, t)
	return {
		math.floor(c1[1] * (1 - t) + c2[1] * t),
		math.floor(c1[2] * (1 - t) + c2[2] * t),
		math.floor(c1[3] * (1 - t) + c2[3] * t),
	}
end

--- Nudge an accent away from extreme luminance on the current theme.
local function adjust(c, light)
	local l = luminance(c)
	local target = light and 70 or 170
	if math.abs(l - target) < 40 then
		return c
	end
	local t = clamp((target - l) / 255, -0.35, 0.35)
	if t >= 0 then
		return blend(c, WHITE, t)
	end
	return blend(c, BLACK, -t)
end

--- Ensure fg_dim keeps >= 60 luminance difference from the reactive bg.
local function adjust_for_contrast(c, target_lum)
	local current = luminance(c)
	if math.abs(target_lum - current) >= 60 then
		return c
	end
	local t = clamp((target_lum - current) / 255, -0.4, 0.4)
	if t >= 0 then
		return blend(c, WHITE, t)
	end
	return blend(c, BLACK, -t)
end

-- ============================================================================
-- Palette extraction
-- ============================================================================

local TOOLS = {
	{
		name = "ffmpeg",
		build = function(input, output)
			return {
				"ffmpeg",
				"-v",
				"error",
				"-nostdin",
				"-i",
				input,
				"-vf",
				"scale=24:24:flags=area",
				"-f",
				"rawvideo",
				"-pix_fmt",
				"rgb24",
				"-y",
				output,
			}
		end,
	},
	{
		name = "magick",
		build = function(input, output)
			return { "magick", input, "-resize", "24x24!", "-depth", "8", output }
		end,
	},
	{
		name = "convert",
		build = function(input, output)
			return { "convert", input, "-resize", "24x24!", "-depth", "8", output }
		end,
	},
}

--- Downscale a cover to 24x24 raw RGB through the first available tool.
--- ffmpeg writes rawvideo (extension irrelevant); ImageMagick needs the `.rgb`
--- suffix to select its raw-RGB coder.
function T.extract(path, cb)
	local tool = nil
	for _, t in ipairs(TOOLS) do
		if vim.fn.executable(t.name) == 1 then
			tool = t
			break
		end
	end
	if not tool then
		vim.schedule(function()
			cb(nil)
		end)
		return
	end
	local output = vim.fn.tempname() .. (tool.name == "ffmpeg" and ".raw" or ".rgb")
	vim.system(tool.build(path, output), { text = true, stderr = "pipe", timeout = 10000 }, function(res)
		vim.schedule(function()
			local ok = res and res.code == 0
			local raw = ok and vim.fn.readfile(output, "b") or nil
			if raw then
				raw = table.concat(raw, "")
			end
			vim.fn.delete(output)
			if raw and #raw >= 3 then
				local palette = T.quantize(raw)
				if palette then
					cb(T.select(palette))
					return
				end
			end
			cb(nil)
		end)
	end)
end

--- 5-bit histogram over raw RGB bytes; returns up to 10 dominant colors
--- ordered by pixel count, averaged within each quantized bucket.
function T.quantize(raw)
	local n = math.floor(#raw / 3)
	if n < 3 then
		return nil
	end
	local order = {} -- bucket -> index into hist
	local hist = {} -- { count, sr, sg, sb }
	for i = 1, n * 3, 3 do
		local r = raw:byte(i)
		local g = raw:byte(i + 1)
		local b = raw:byte(i + 2)
		local key = math.floor(r / 8) * 1024 + math.floor(g / 8) * 32 + math.floor(b / 8)
		local idx = order[key]
		if not idx then
			idx = #hist + 1
			order[key] = idx
			hist[idx] = { 0, 0, 0, 0 }
		end
		local e = hist[idx]
		e[1] = e[1] + 1
		e[2] = e[2] + r
		e[3] = e[3] + g
		e[4] = e[4] + b
	end
	table.sort(hist, function(a, b)
		return a[1] > b[1]
	end)
	local palette = {}
	local top = math.min(10, #hist)
	for i = 1, top do
		local e = hist[i]
		palette[i] = { math.floor(e[2] / e[1]), math.floor(e[3] / e[1]), math.floor(e[4] / e[1]) }
	end
	return palette
end

--- Pick primary/secondary/tertiary from a dominant-color list.
--- Secondary maximizes hue distance + chroma from the primary (sat > 0.12
--- gate so muddy grays never hijack accents); population order breaks ties.
function T.select(palette)
	if not palette or #palette == 0 then
		return nil
	end
	local primary = palette[1]
	local ph = rgb_to_hsv(primary) -- primary hue
	local secondary, tertiary
	local best = -1
	for i = 2, #palette do
		local v = palette[i]
		local h, s = rgb_to_hsv(v)
		local gap = hue_distance(ph, h)
		local score = gap + 2 * s
		if score > best and s > 0.12 then
			best = score
			tertiary = secondary
			secondary = v
		elseif not tertiary then
			tertiary = v
		end
	end
	local function fallback_mix(c, t)
		local shifted = hue_shift(c, 0.33)
		return {
			math.floor(c[1] * (1 - t) + shifted[1] * t),
			math.floor(c[2] * (1 - t) + shifted[2] * t),
			math.floor(c[3] * (1 - t) + shifted[3] * t),
		}
	end
	secondary = secondary or fallback_mix(primary, 1)
	tertiary = tertiary or fallback_mix(secondary, 1)
	return { primary = primary, secondary = secondary, tertiary = tertiary }
end

-- ============================================================================
-- Highlight group management
-- ============================================================================

--- 24-bit int -> {r,g,b} with graceful fallbacks.
local function to_rgb(v, ...)
	if type(v) == "number" then
		return { math.floor(v / 65536), math.floor(v / 256) % 256, v % 256 }
	end
	for _, f in ipairs({ ... }) do
		if type(f) == "number" then
			return to_rgb(f)
		end
		if type(f) == "table" then
			return f
		end
	end
	return { 30, 30, 30 }
end

local ALL_GROUPS = nil

function T.groups()
	if not ALL_GROUPS then
		ALL_GROUPS = {}
		vim.list_extend(ALL_GROUPS, FLOAT_GROUPS)
		vim.list_extend(ALL_GROUPS, GTM_GROUPS)
	end
	return ALL_GROUPS
end

--- Define the Gtm* links against the current colorscheme.
function T._define_links()
	for name, link in pairs(BASE_LINKS) do
		vim.api.nvim_set_hl(0, name, { link = link })
	end
end

--- Snapshot every overridable group (with link info) plus the base colors
--- used by derive(). Called on setup and on every ColorScheme.
function T.snapshot()
	local groups = {}
	local extra = T._opts.extra_groups or {}
	vim.list_extend(groups, FLOAT_GROUPS)
	vim.list_extend(groups, GTM_GROUPS)
	vim.list_extend(groups, extra)
	for _, name in ipairs(groups) do
		T._snap[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
	end

	local nf = vim.api.nvim_get_hl(0, { name = "NormalFloat" })
	local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
	local border = vim.api.nvim_get_hl(0, { name = "FloatBorder" })
	local comment = vim.api.nvim_get_hl(0, { name = "Comment" })
	T._base = {
		bg = to_rgb(nf.bg, normal.bg, { 30, 30, 30 }),
		fg = to_rgb(nf.fg, normal.fg, { 212, 212, 212 }),
		border = to_rgb(border.fg, nf.fg, normal.fg, { 138, 138, 138 }),
		fg_dim = to_rgb(comment.fg, nf.fg, normal.fg, { 138, 138, 138 }),
	}
end

--- Restore every overridden group to its snapshot (removes the tint).
function T.restore()
	for name, saved in pairs(T._snap) do
		vim.api.nvim_set_hl(0, name, saved)
	end
	T._palette = nil
	T._derived = nil
end

function T.is_active()
	return T._palette ~= nil
end

--- Whether reactive theming is switched on via opts.theme.reactive.
function T.is_enabled()
	return T._opts.reactive or false
end

function T.current_palette()
	return T._palette
end

--- setup: register opts, define links, snapshot the theme's base state.
function T.setup(opts)
	T._opts = vim.tbl_deep_extend("force", T._opts, opts or {})
	T._define_links()
	T.snapshot()
end

--- Re-establish links + fresh snapshot after a colorscheme swap, and re-apply
--- the active palette so the tint survives theme changes.
function T.rebundle()
	T._define_links()
	T.snapshot()
	if T._palette then
		T.apply(T._palette)
	end
end

--- Derive per-group attrs from a palette + the snapshotted base colors.
function T._derive(pal)
	local base = T._base
	local light = luminance(base.bg) > 128
	local primary = adjust(pal.primary, light)
	local secondary = adjust(pal.secondary, light)
	local tertiary = adjust(pal.tertiary, light)

	-- Ambient wash of the raw dominant color (Rust: `primary_raw`).
	local intensity = clamp(T._opts.intensity or 0.2, 0, 0.5)
	local unified_bg = blend(base.bg, pal.primary, intensity)
	local border = blend(base.border, primary, 0.55)

	-- Keep the dim foreground readable against the reactive background.
	local bg_lum = luminance(pal.primary)
	local target_dim = bg_lum > 128 and (bg_lum - 60) or (bg_lum + 60)
	local fg_dim = adjust_for_contrast(base.fg_dim, target_dim)

	local derived = {
		NormalFloat = { fg = base.fg, bg = unified_bg },
		FloatBorder = { fg = border, bg = unified_bg },
		FloatTitle = { fg = primary, bg = unified_bg, bold = true },
		FloatFooter = { fg = fg_dim, bg = unified_bg },
		GtmIcon = { fg = primary, bg = unified_bg },
		GtmTitle = { fg = base.fg, bg = unified_bg },
		GtmArtist = { fg = secondary, bg = unified_bg },
		GtmAlbum = { fg = tertiary, bg = unified_bg },
		GtmTime = { fg = secondary, bg = unified_bg },
		GtmBar = { fg = primary, bg = unified_bg },
		GtmBarEmpty = { fg = fg_dim, bg = unified_bg },
		GtmVolume = { fg = fg_dim, bg = unified_bg },
		GtmHint = { fg = fg_dim, bg = unified_bg },
	}
	for _, name in ipairs(T._opts.extra_groups or {}) do
		local saved = T._snap[name] or {}
		derived[name] = { fg = saved.fg, bg = unified_bg }
	end
	return derived
end

--- Tuples → "#rrggbb"; pass through anything nvim_set_hl accepts natively.
local function cstr(c)
	if type(c) == "table" then
		return string.format("#%02x%02x%02x", c[1], c[2], c[3])
	end
	return c
end

--- Apply a palette: derive and set every group, mutating global highlights.
function T.apply(pal)
	if not pal then
		return
	end
	local derived = T._derive(pal)
	T._palette = pal
	T._derived = derived
	for name, attrs in pairs(derived) do
		local hl = {}
		if attrs.fg then
			hl.fg = cstr(attrs.fg)
		end
		if attrs.bg then
			hl.bg = cstr(attrs.bg)
		end
		if attrs.bold then
			hl.bold = true
		end
		vim.api.nvim_set_hl(0, name, hl)
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
	local res = {
		primary = hx(pal.primary),
		secondary = hx(pal.secondary),
		tertiary = hx(pal.tertiary),
	}
	if T._derived then
		res.bg = hx(T._derived.NormalFloat.bg)
	else
		res.bg = "n/a"
	end
	return res
end

return T

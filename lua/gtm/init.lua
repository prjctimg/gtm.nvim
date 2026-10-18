-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.nvim: Neovim wrapper for the GTM daemon
--
-- Playback control, a statusline, and reactive theming. No windows: those belong
-- to gtmd and its TUI.
--
-- This is free software released under the GPL-3.0 license.

local G = {}
local ipc = require("gtm.ipc")
local pulse = require("gtm.pulse")
local theme = require("gtm.theme")
local uv = vim.uv

local defaults = {
	resync_interval = 30000,
	-- Statusline items, rendered in table order. The default shows the source
	-- marker and the state icon; everything else is opt-in, so nothing is
	-- squeezed in by default.
	statusline = {
		source = true,
		state = true,
		artist = false,
		title = false,
		album = false,
		progress = false,
		time = false,
		volume = false,
		["repeat"] = false,
		shuffle = false,
		-- Source markers: Nerd Font, Material Design Icons in the Plane 15 PUA, so
		-- four UTF-8 bytes each and four \x escapes. README has the plain-Unicode
		-- set for terminals with no patched font.
		icons = {
			spotify = "\xf3\xb0\x93\x87", -- md-spotify      U+F04C7
			radio = "\xf3\xb0\x90\xb9", -- md-radio        U+F0439
			podcast = "\xf3\xb0\xa6\x94", -- md-podcast      U+F0994
			["local"] = "\xf3\xb1\x8d\x99", -- md-folder_music U+F1359
			chart = "\xf3\xb0\x84\xaa", -- md-chart_line   U+F012A
		},
	},
	theme = { reactive = true, extra_groups = {} },
	keymaps = {},
}

G.opts = vim.deepcopy(defaults)
local resync = nil

--- 0.1.x configured `statusline_format`; map it onto the item table so an old
--- config keeps its items instead of silently dropping to one icon.
local function migrate(opts)
	if not opts or not opts.statusline_format or opts.statusline then
		return opts
	end
	local on = {}
	for _, item in ipairs({ "artist", "title", "album", "progress", "time", "volume", "repeat", "shuffle" }) do
		on[item] = opts.statusline_format ~= "compact"
	end
	return vim.tbl_extend("force", vim.deepcopy(opts), { statusline = on })
end

-- Playback: each is a single command send.
function G.play_pause() ipc.send("play_pause") end
function G.next() ipc.send("next") end
function G.prev() ipc.send("prev") end
function G.stop() ipc.send("stop") end
function G.mute() ipc.send("toggle_mute") end
function G.shuffle() ipc.send("toggle_shuffle") end

-- The wire is PascalCase; the plugin keeps lowercase. `repeat` is a Lua
-- keyword, so the public name cannot be `G.repeat`.
local REPEAT_WIRE = { off = "Off", one = "One", all = "All" }
local REPEAT_NEXT = { off = "One", one = "All", all = "Off" }

--- Set the repeat mode; with no argument, advance off -> one -> all -> off.
function G.cycle_repeat(mode)
	local cur = mode or (ipc.status and ipc.status["repeat"]) or "off"
	-- Only an explicit mode needs translating; cycling stays in lowercase.
	local wire = mode and REPEAT_WIRE[mode] or REPEAT_NEXT[cur] or REPEAT_WIRE.off
	ipc.send("cycle_repeat", { mode = wire })
end

function G.seek(secs)
	if type(secs) == "number" then
		ipc.send("seek", { position_secs = secs })
	end
end

function G.set_volume(delta)
	local vol = math.max(0, math.min(100, (ipc.status and ipc.status.volume or 80) + delta))
	ipc.send("set_volume", { volume = vol })
end

-- Statusline --------------------------------------------------------------

local ICON = { playing = "▶", paused = "⏸", stopped = "⏹" }

local function fmt_time(secs)
	return string.format("%02d:%02d", math.floor(secs / 60), math.floor(secs % 60))
end

--- Render the enabled items. Each is skipped when off or when it has no data,
--- which is what makes the empty state a bare stop icon rather than a row of
--- zeroes.
function G.statusline()
	local s, on, out = ipc.status, G.opts.statusline, {}
	local t = s and s.current_track
	local function add(text)
		if text then
			table.insert(out, text)
		end
	end

	-- A source gtmd has not named yet renders as nothing rather than guessing.
	add(on.source and s and on.icons[s.source])
	add(on.state and (ICON[s and s.status] or "⏹"))

	if t then
		add(on.artist and t.artist)
		add(on.title and t.title)
		add(on.album and t.album)
		if on.progress then
			local width, pos, dur = 20, ipc.position(), ipc.duration()
			local filled = dur > 0 and math.floor(math.min(1, pos / dur) * width) or 0
			add(string.rep("━", filled) .. string.rep("─", width - filled))
		end
		if on.time then
			add(string.format("[%s/%s]", fmt_time(ipc.position()), fmt_time(ipc.duration())))
		end
		add(on.volume and string.format("vol:%d%%", s.volume or 0))
		add(on["repeat"] and s["repeat"] and s["repeat"] ~= "off" and "[R]")
		add(on.shuffle and s.shuffle and "[S]")
	end

	return table.concat(out, " ")
end

--- Drop-in lualine component, hidden while the daemon is unreachable so a
--- stopped gtmd costs no width.
function G.lualine_component()
	return {
		G.statusline,
		cond = function()
			return ipc.connected
		end,
	}
end

-- Events ------------------------------------------------------------------

--- A pause keeps the tint: you stopped to browse, not to forget the record. Only
--- a real stop or a track end gives the editor back its own colours.
local function unpaint()
	theme.clear()
end

--- Build a handler that lifts one scalar off an event into the snapshot.
local function patch(key, field)
	return function(ev) ipc.patch(key, ev[field]) end
end

local HANDLERS = {
	playback_started = ipc.apply,
	playback_paused = ipc.apply,
	playback_stopped = function(ev)
		ipc.apply(ev)
		unpaint()
	end,
	track_ended = function()
		ipc.clear()
		unpaint()
	end,
	volume_changed = patch("volume", "volume"),
	shuffle_changed = patch("shuffle", "enabled"),
	-- RepeatMode serializes PascalCase on the wire ("One"/"All"/"Off"); keep
	-- the lowercase form everywhere in the plugin.
	repeat_mode_changed = function(ev)
		ipc.patch("repeat", (ev.mode or ""):lower())
	end,
	reactive_theme = theme.set_roles,
}

-- Commands ----------------------------------------------------------------

local function notify_status()
	local s = ipc.status
	local t = s and s.current_track
	if not t then
		return vim.notify("[gtm] nothing playing")
	end
	local icon = ICON[s.status] or "⏹"
	vim.notify(string.format("[gtm] %s %s - %s", icon, t.artist or "?", t.title or "?"))
end

local function notify_theme(arg)
	if arg == "reset" then
		unpaint()
		return vim.notify("[gtm] reactive theme cleared")
	end
	if not theme.enabled() then
		return vim.notify("[gtm] reactive theming is off (theme.reactive = true)")
	end
	if not theme.roles() then
		return vim.notify("[gtm] no palette from the daemon yet")
	end
	local a, b, c = theme.palette_hexes()
	vim.notify(string.format("[gtm] %s %s %s", a, b, c))
end

--- One entry per `:Gtm` subcommand. `arg = true` means it takes a second
--- argument; `key` and `desc` drive an opt-in keymap. One table so the command
--- surface, the keymaps and the completion list cannot drift apart.
local CMDS = {
	{ name = "play", key = "play_pause", desc = "play/pause", run = G.play_pause },
	{ name = "next", key = "next", desc = "next track", run = G.next },
	{ name = "prev", key = "prev", desc = "previous track", run = G.prev },
	{ name = "stop", key = "stop", desc = "stop", run = G.stop },
	{ name = "volup", key = "volume_up", desc = "volume up", run = function() G.set_volume(5) end },
	{ name = "voldown", key = "volume_down", desc = "volume down", run = function() G.set_volume(-5) end },
	{ name = "mute", run = G.mute },
	{ name = "shuffle", run = G.shuffle },
	{ name = "status", run = notify_status },
	{
		name = "seek", arg = true,
		run = function(arg)
			local secs = tonumber(arg)
			if secs then
				G.seek(secs)
			else
				vim.notify("Gtm seek: expected seconds", vim.log.levels.ERROR)
			end
		end,
	},
	{ name = "repeat", arg = true, run = G.cycle_repeat },
	{ name = "theme", arg = true, run = notify_theme },
}

local SUBCOMPLETION = { ["repeat"] = { "off", "one", "all" }, theme = { "status", "reset" } }

local function complete(lead, cmdline)
	local parts = vim.split(cmdline, "%s+")
	local list = #parts <= 2 and vim.tbl_map(function(c)
		return c.name
	end, CMDS) or SUBCOMPLETION[parts[2]] or {}
	return vim.tbl_filter(function(s)
		return s:find(lead, 1, true) == 1
	end, list)
end

local function register()
	vim.api.nvim_create_user_command("Gtm", function(args)
		for _, c in ipairs(CMDS) do
			if c.name == args.fargs[1] then
				-- Not `c.arg and c.run(x) or c.run()`: a run that returns nil
				-- would fall through and execute twice.
				if c.arg then
					return c.run(args.fargs[2])
				end
				return c.run()
			end
		end
		vim.notify("Gtm: unknown subcommand '" .. tostring(args.fargs[1]) .. "'", vim.log.levels.ERROR)
	end, { nargs = "+", complete = complete })

	local km = G.opts.keymaps or {}
	for _, c in ipairs(CMDS) do
		local lhs = c.key and km[c.key]
		if lhs then
			vim.keymap.set("n", lhs, c.run, { desc = "GTM: " .. c.desc })
		end
	end
end

-- Setup -------------------------------------------------------------------

local function stop_resync()
	if resync then
		resync:stop()
		resync:close()
		resync = nil
	end
end

--- Slow `get_status_lite` poll. Not the primary update path — the pulse stream
--- is — just a floor under drift we were never told about.
local function start_resync()
	stop_resync()
	resync = uv.new_timer()
	resync:start(G.opts.resync_interval, G.opts.resync_interval, function()
		ipc.send("get_status_lite", nil, function(resp)
			if resp and resp.state then
				ipc.set_status(resp.state)
			end
		end)
	end)
end

function G.setup(opts)
	G.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), migrate(opts) or {})
	theme.setup(G.opts.theme)

	-- Tell the loader (and any other host) that setup is owned; see
	-- plugin/gtm.lua. Safe to set before the rest of the body runs.
	vim.g.loaded_gtm = true

	-- Idempotent: a config reload, or the loader's default auto-setup racing the
	-- host's explicit call, must not duplicate sockets, handlers or autocmds.
	if G._wired then
		start_resync()
		return G
	end
	G._wired = true

	for name, handler in pairs(HANDLERS) do
		pulse.on(name, handler)
	end
	-- The command socket owns reconnection, so the pulse socket is re-claimed on
	-- every (re)connect rather than growing its own retry loop.
	ipc.connect(G.opts.socket_path, function()
		pulse.connect(ipc.pulse_path())
	end)
	register()
	start_resync()

	vim.api.nvim_create_autocmd("ColorScheme", { desc = "GTM: re-derive reactive theme", callback = theme.on_colorscheme })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		desc = "GTM: release daemon resources",
		callback = function()
			stop_resync()
			pulse.close()
			ipc.disconnect()
			theme.restore()
		end,
	})

	return G
end

return G
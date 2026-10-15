-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.nvim: Neovim wrapper for the GTM daemon
--
-- Three things and nothing else: playback control, a statusline, and reactive
-- theming driven by the album art the daemon already extracted. Any window,
-- list or picker belongs to gtmd and its TUI, not to a plugin that has to stay
-- small enough to read in one sitting.
--
-- This is free software released under the GPL-3.0 license.

local G = {}
local ipc = require("gtm.ipc")
local pulse = require("gtm.pulse")
local theme = require("gtm.theme")
local uv = vim.uv

local defaults = {
	socket_path = nil,
	statusline_format = "compact", -- "compact" | "detailed"
	resync_interval = 30000,
	theme = { reactive = false, extra_groups = {} },
	keymaps = {
		play_pause = "<leader>gp",
		next = "<leader>gn",
		prev = "<leader>gN",
		volume_up = "<leader>g>",
		volume_down = "<leader>g<",
		stop = "<leader>gS",
	},
}

G.opts = vim.deepcopy(defaults)
local resync = nil

-- Playback: every one of these is a single command send.
function G.play_pause()
	ipc.send("play_pause")
end

function G.next()
	ipc.send("next")
end

function G.prev()
	ipc.send("prev")
end

function G.stop()
	ipc.send("stop")
end

function G.mute()
	ipc.send("toggle_mute")
end

function G.shuffle()
	ipc.send("toggle_shuffle")
end

--- RepeatMode arrives PascalCase on the wire; accept the lowercase a user types.
--- (`repeat` is a Lua keyword, so the public name cannot be `G.repeat`.)
local REPEAT_MODES = { off = "Off", one = "One", all = "All" }

function G.cycle_repeat(mode)
	ipc.send("cycle_repeat", { mode = REPEAT_MODES[mode] or mode })
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
	return secs and secs >= 0 and string.format("%02d:%02d", math.floor(secs / 60), math.floor(secs % 60)) or "00:00"
end

local function bar(pos, dur, width)
	local filled = dur > 0 and math.floor(math.min(1, pos / dur) * width) or 0
	return string.rep("━", filled) .. string.rep("─", width - filled)
end

--- `artist - title`, or nil when nothing is loaded. An empty statusline is
--- quieter than a placeholder.
local function line()
	local t = ipc.status and ipc.status.current_track
	return type(t) == "table" and ((t.artist or "Unknown") .. " - " .. (t.title or "Unknown")) or nil
end

local function compact()
	local s, name = ipc.status, line()
	if not name then
		return ""
	end
	local icon, vol = ICON[s.status] or "⏹", s.volume or 0
	local progress = bar(ipc.position(), ipc.duration(), 20)
	return string.format("%s %s vol:%d%% %s", name, icon, vol, progress)
end

local function detailed()
	local s, name = ipc.status, line()
	if not name then
		return "GTM - not playing"
	end
	local parts = { ICON[s.status] or "⏹", name }
	local function put(text)
		parts[#parts + 1] = text
	end
	if s.current_track.album and s.current_track.album ~= "" then
		put("(" .. s.current_track.album .. ")")
	end
	put(string.format("[%s/%s] vol:%d%%", fmt_time(ipc.position()), fmt_time(ipc.duration()), s.volume or 0))
	if s["repeat"] and s["repeat"] ~= "off" then
		put("[R]")
	end
	if s.shuffle then
		put("[S]")
	end
	return table.concat(parts, " ")
end

function G.statusline()
	return G.opts.statusline_format == "detailed" and detailed() or compact()
end

--- Drop-in lualine component, hidden while the daemon is unreachable so a
--- stopped gtmd costs no width.
function G.lualine_component()
	return {
		compact,
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
	return function(ev)
		ipc.patch(key, ev[field])
	end
end

local HANDLERS = {
	playback_started = ipc.apply,
	playback_paused = ipc.apply,
	playback_stopped = function(ev)
		ipc.apply(ev)
		unpaint()
	end,
	track_ended = function()
		ipc.status = nil
		unpaint()
	end,
	volume_changed = patch("volume", "volume"),
	shuffle_changed = patch("shuffle", "enabled"),
	-- RepeatMode serializes PascalCase on the wire ("One"/"All"/"Off"); keep
	-- the lowercase form everywhere in the plugin.
	repeat_mode_changed = function(ev)
		ipc.patch("repeat", (ev.mode or ""):lower())
	end,
	duration_changed = patch("duration", "duration"),
	-- Internet radio learns the real track name after the stream starts.
	radio_title_changed = function(ev)
		if ev.title and ipc.status then
			ipc.status.current_track = vim.tbl_extend("force", ipc.status.current_track or {}, { title = ev.title })
		end
	end,
	reactive_palette = function(ev)
		-- Fallback path: three hex strings, only from a daemon too old to send
		-- resolved role sets. `apply` clears the tint when they are empty, which
		-- is the daemon saying it had no art rather than that the art is black.
		theme.apply(ev)
	end,
	-- Preferred path: gtmd resolved the whole ramp and sends both polarities.
	-- Ignored if the role set is incomplete, so a mixed-version daemon can
	-- never half-tint.
	reactive_theme = function(ev)
		theme.set_roles(ev)
	end,
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
		vim.notify("[gtm] reactive theme cleared")
	elseif not theme.enabled() then
		vim.notify("[gtm] reactive theming is off (theme.reactive = true)")
		return
	end
	local pal = theme.palette()
	if not pal then
		return vim.notify("[gtm] no palette from the daemon yet")
	end
	local h = theme.palette_hexes(pal)
	vim.notify(string.format("[gtm] %s %s %s", h.primary, h.secondary, h.tertiary))
end

function G.disconnect()
	ipc.disconnect()
	pulse.close()
	vim.notify("[gtm] disconnected")
end

--- Subcommands taking a second argument.
local ARGUMENTARY = {
	seek = function(arg)
		local secs = tonumber(arg)
		if secs then
			G.seek(secs)
		else
			vim.notify("Gtm seek: expected seconds", vim.log.levels.ERROR)
		end
	end,
	["repeat"] = function(arg)
		G.cycle_repeat(arg or "all")
	end,
	theme = notify_theme,
}

--- `name` is the :Gtm subcommand, `key` the opts.keymaps entry, `desc` the
--- keymap description. One table drives both surfaces so they cannot drift.
local ACTIONS = {
	{ name = "play", key = "play_pause", desc = "play/pause", run = G.play_pause },
	{ name = "next", key = "next", desc = "next track", run = G.next },
	{ name = "prev", key = "prev", desc = "previous track", run = G.prev },
	{ name = "stop", key = "stop", desc = "stop", run = G.stop },
	{ name = "volup", key = "volume_up", desc = "volume up", run = function() G.set_volume(5) end },
	{ name = "voldown", key = "volume_down", desc = "volume down", run = function() G.set_volume(-5) end },
	{ name = "mute", run = G.mute },
	{ name = "shuffle", run = G.shuffle },
	{ name = "status", run = notify_status },
	{ name = "disconnect", run = G.disconnect },
}

local SUBS = {}
for _, a in ipairs(ACTIONS) do
	SUBS[#SUBS + 1] = a.name
end
for name in pairs(ARGUMENTARY) do
	SUBS[#SUBS + 1] = name
end
table.sort(SUBS)

local function prefix(list, lead)
	return vim.tbl_filter(function(s)
		return s:find(lead, 1, true) == 1
	end, list)
end

function G.register()
	vim.api.nvim_create_user_command("Gtm", function(args)
		local with_arg = ARGUMENTARY[args.fargs[1]]
		if with_arg then
			return with_arg(args.fargs[2])
		end
		for _, a in ipairs(ACTIONS) do
			if a.name == args.fargs[1] then
				return a.run()
			end
		end
		vim.notify("Gtm: unknown subcommand '" .. tostring(args.fargs[1]) .. "'", vim.log.levels.ERROR)
	end, {
		nargs = "+",
		complete = function(lead, cmdline)
			local parts = vim.split(cmdline, "%s+")
			if #parts <= 2 then
				return prefix(SUBS, lead)
			elseif parts[2] == "repeat" then
				return prefix({ "off", "one", "all" }, lead)
			elseif parts[2] == "theme" then
				return prefix({ "status", "reset" }, lead)
			end
			return {}
		end,
	})

	local km = G.opts.keymaps or {}
	for _, a in ipairs(ACTIONS) do
		local lhs = a.key and km[a.key]
		if lhs then
			vim.keymap.set("n", lhs, a.run, { desc = "GTM: " .. a.desc })
		end
	end
end

-- Setup -------------------------------------------------------------------

--- Slow `get_status_lite` poll. Not the primary update path — the pulse stream
--- is — just a floor under drift we were never told about.
local function start_resync()
	if resync then
		resync:stop()
		resync:close()
	end
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
	G.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
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
	-- The command socket owns reconnection, so the pulse socket is re-claimed
	-- here rather than growing its own retry loop.
	ipc._on_connect = function()
		pulse.connect(ipc.pulse_path())
	end

	ipc.connect(G.opts.socket_path)
	G.register()
	start_resync()

	vim.api.nvim_create_autocmd("ColorScheme", { desc = "GTM: re-derive reactive theme", callback = theme.on_colorscheme })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		desc = "GTM: release daemon resources",
		callback = function()
			if resync then
				resync:stop()
				resync:close()
				resync = nil
			end
			pulse.close()
			ipc.disconnect()
			theme.restore()
		end,
	})

	return G
end

function G.reset_theme()
	theme.clear()
end

return G
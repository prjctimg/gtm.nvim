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

-- Playback: each is a single command send.
function G.play_pause() ipc.send("play_pause") end
function G.next() ipc.send("next") end
function G.prev() ipc.send("prev") end
function G.stop() ipc.send("stop") end
function G.mute() ipc.send("toggle_mute") end
function G.shuffle() ipc.send("toggle_shuffle") end

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
	return string.format("%02d:%02d", math.floor(secs / 60), math.floor(secs % 60))
end

local function bar(pos, dur)
	local filled = dur > 0 and math.floor(math.min(1, pos / dur) * 20) or 0
	return string.rep("━", filled) .. string.rep("─", 20 - filled)
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
	return string.format("%s %s vol:%d%% %s", name, icon, vol, bar(ipc.position(), ipc.duration()))
end

local function detailed()
	local s, name = ipc.status, line()
	if not name then
		return "GTM - not playing"
	end
	local parts = { ICON[s.status] or "⏹", name }
	if s.current_track.album and s.current_track.album ~= "" then
		table.insert(parts, "(" .. s.current_track.album .. ")")
	end
	local clock = string.format("[%s/%s]", fmt_time(ipc.position()), fmt_time(ipc.duration()))
	table.insert(parts, string.format("%s vol:%d%%", clock, s.volume or 0))
	if s["repeat"] and s["repeat"] ~= "off" then
		table.insert(parts, "[R]")
	end
	if s.shuffle then
		table.insert(parts, "[S]")
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
	duration_changed = patch("duration", "duration"),
	-- Internet radio learns the real track name after the stream starts.
	radio_title_changed = function(ev)
		if ev.title and ipc.status then
			ipc.status.current_track = vim.tbl_extend("force", ipc.status.current_track or {}, { title = ev.title })
		end
	end,
	-- Fallback path: three hex strings, only from a daemon too old to send
	-- resolved role sets. `apply` clears the tint when they are empty, which is
	-- the daemon saying it had no art rather than that the art is black.
	reactive_palette = theme.apply,
	-- Preferred path: gtmd resolved the whole ramp and sends both polarities.
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

local function disconnect()
	ipc.disconnect()
	pulse.close()
	vim.notify("[gtm] disconnected")
end

--- One entry per `:Gtm` subcommand. `arg = true` means it takes a second
--- argument; `key` and `desc` drive the default keymap. One table so the command
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
	{ name = "disconnect", run = disconnect },
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
	{ name = "repeat", arg = true, run = function(arg) G.cycle_repeat(arg or "all") end },
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
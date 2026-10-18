-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.health: `:checkhealth gtm`
--
-- Answers the three questions worth asking when nothing is happening: is gtmd
-- installed, are both sockets actually live, and is the status snapshot moving.
-- Works before `setup()` has run, so it never assumes configuration exists.
--
-- This is free software released under the GPL-3.0 license.

local M = {}
local H = vim.health
local stat = vim.uv.fs_stat
local ipc = require("gtm.ipc")
local pulse = require("gtm.pulse")
local theme = require("gtm.theme")

-- gtmd pushes `heartbeat` continuously, so anything much older than this means
-- the pulse listener is wedged even though the command socket looks healthy.
local STALE_HEARTBEAT = 60

--- One check, one line: report `good` when `ok`, `bad` otherwise. `level` picks
--- the failure severity and defaults to a warning.
local function check(ok, good, bad, level)
	H[ok and "ok" or (level or "warn")](ok and good or bad)
end

local function ago(seconds)
	return string.format("%.0fs ago", seconds)
end

local function requirements()
	H.start("gtm: requirements")
	local has_nvim = vim.fn.has("nvim-0.11") == 1
	check(has_nvim, "Neovim " .. tostring(vim.version()), "gtm.nvim needs Neovim 0.11 or newer", "error")
	local has_daemon = vim.fn.executable("gtmd") == 1
	local found = "gtmd on $PATH (" .. vim.fn.exepath("gtmd") .. ")"
	check(has_daemon, found, "gtmd is not on $PATH - install it from github.com/prjctimg/gtm", "error")
end

local function daemon()
	H.start("gtm: daemon")
	local cmd, pul = ipc.path or ipc.resolve_path(), ipc.pulse_path()
	check(stat(cmd), "command socket: " .. cmd, "no command socket at " .. cmd, "error")
	check(stat(pul), "pulse socket: " .. pul, "no pulse socket at " .. pul, "error")
	check(ipc.connected, "command socket connected", "not connected - playback commands will be dropped")
	check(pulse.is_connected(), "pulse socket connected", "not connected - the statusline will not update on its own")

	local age = pulse.heartbeat_age()
	if age == nil then
		H.warn("no heartbeat received yet")
	else
		local msg = "last heartbeat " .. ago(age)
		check(age <= STALE_HEARTBEAT, msg, msg .. " - the daemon looks wedged")
	end
end

local function status()
	H.start("gtm: status")
	local s = ipc.status
	if not s then
		return H.warn("no status snapshot yet")
	end
	local t = s.current_track or {}
	H.ok(string.format("%s %s - %s", s.status, t.artist or "?", t.title or "?"))
	local shuffle = tostring(s.shuffle)
	H.info(string.format("volume %d%%, repeat %s, shuffle %s", s.volume or 0, s["repeat"] or "off", shuffle))
	H.info(string.format("position %ds of %ds", ipc.position(), ipc.duration()))
	H.info("snapshot updated " .. ago(ipc.stale_for()))
end

local function theming()
	H.start("gtm: theming")
	if not theme.enabled() then
		return H.info("reactive theming is off - set theme.reactive = true to enable it")
	end
	local roles = theme.roles()
	if not roles then
		return H.warn("enabled, but no role set has arrived - this gtmd may predate reactive_theme")
	end
	local a, b, c = theme.palette_hexes()
	H.ok(string.format("tinted: %s %s %s", a, b, c))
	H.ok(string.format("role set v%s, resolved by gtmd", tostring(theme.version())))
end

function M.check()
	requirements()
	daemon()
	status()
	theming()
end

return M
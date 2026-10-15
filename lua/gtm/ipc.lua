-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.ipc: command-socket half of the gtmd protocol
--
-- One Unix socket, newline-delimited JSON: requests out, responses back
-- correlated by the `id` we chose. gtmd pushes no events here, so this module
-- does two things only — keep a live socket, and hold the snapshot the UI reads.
--
-- Drift is handled by extrapolation, not polling: the pulse stream (`gtm.pulse`)
-- delivers transitions and `position()` advances the clock between them. The
-- slow `get_status_lite` resync only exists to heal drift we never heard about.
--
-- This is free software released under the GPL-3.0 license.

local I = {}
local uv = vim.uv
local hrtime = uv.hrtime

I.sock = nil
I.path = nil
I.connected = false
I.status = nil

local MAX_LINE = 1024 * 1024
local RETRY_MAX_DELAY = 10000
local MAX_ATTEMPTS = 30

local id, buf, pending = 0, "", {}
local retry_timer, delay, attempts = nil, 500, 0
local base_pos, base_time, duration, updated = 0, 0, 0, 0

-- `vim.NIL` (JSON null) decodes to a truthy sentinel that slips through plain
-- `if x then` idioms and then crashes on indexing — gtmd sends
-- `current_track: null` while idle. Deep-normalize it to real nil at the payload
-- boundary; the copy also stops decoded messages aliasing each other.
local function denil(v)
	if v == vim.NIL then
		return nil
	elseif type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in pairs(v) do
		out[k] = denil(val)
	end
	return out
end

--- Where gtmd puts its command socket, in the daemon's own search order. The
--- last candidate comes back unchecked so a daemon that has not started yet
--- still has a path to report.
function I.resolve_path()
	local runtime, tmpdir = os.getenv("XDG_RUNTIME_DIR"), os.getenv("TMPDIR")
	local user = os.getenv("USER") or os.getenv("LOGNAME") or "root"
	for _, path in ipairs({
		runtime and (runtime .. "/gtm/gtmd.sock"),
		"/tmp/gtm-" .. user .. "/gtm/gtmd.sock",
		tmpdir and (tmpdir .. "/gtm/gtmd.sock"),
	}) do
		if path and uv.fs_stat(path) then
			return path
		end
	end
	return (os.getenv("HOME") or "/tmp") .. "/.gtm/gtm/gtmd.sock"
end

--- The pulse socket is the command socket's sibling.
function I.pulse_path()
	return (I.path or I.resolve_path()):gsub("gtmd%.sock$", "gtmd.pulse")
end

function I.connect(path)
	I.path = path or I.resolve_path()
	if uv.fs_stat(I.path) then
		I._open()
	else
		-- Start the daemon yourself: a plugin silently spawning a server process
		-- is not its call to make, and there is nothing to reconnect to anyway.
		vim.notify("[gtm] gtmd is not running (no socket at " .. I.path .. ")", vim.log.levels.WARN)
	end
end

function I.disconnect()
	if retry_timer then
		retry_timer:stop()
		retry_timer:close()
		retry_timer = nil
	end
	if I.sock then
		I.sock:read_stop()
		I.sock:close()
		I.sock = nil
	end
	I.connected = false
	I.status = nil
	pending = {}
end

function I._open()
	if I.sock then
		return
	end
	local sock = uv.new_pipe(false)
	I.sock = sock
	sock:connect(I.path, function(err)
		-- A stale handle from a racing retry can land here late; the `~=` check
		-- drops it instead of resurrecting a dead pipe.
		if err or I.sock ~= sock then
			sock:close()
			I.sock = nil
			I._retry()
			return
		end
		I.connected = true
		delay, attempts = 500, 0
		I._read(sock)
		-- Prime on (re)connect so the statusline is right even when nothing has
		-- been played yet — a daemon sitting paused on a radio stream.
		I.send("get_status", nil, function(resp)
			if resp and resp.state then
				I.set_status(resp.state)
			end
			if I._on_connect then
				I._on_connect()
			end
		end)
	end)
end

--- Exponential backoff, capped, and never more than one timer in flight.
function I._retry()
	I.connected = false
	if retry_timer or not I.path then
		return
	end
	retry_timer = uv.new_timer()
	retry_timer:start(delay, 0, function()
		if retry_timer then
			retry_timer:stop()
			retry_timer:close()
			retry_timer = nil
		end
		attempts = attempts + 1
		if attempts > MAX_ATTEMPTS then
			vim.notify("[gtm] gave up reconnecting to gtmd", vim.log.levels.ERROR)
			return
		end
		delay = math.min(delay * 2, RETRY_MAX_DELAY)
		I._open()
	end)
end

--- Responses are one JSON object per line. Anything else arriving here is not a
--- response for us, so it is skipped rather than parsed.
function I._read(sock)
	buf = ""
	sock:read_start(function(err, data)
		if err or not data then
			I.connected = false
			I._retry()
			return
		end
		buf = buf .. data
		while true do
			local nl = buf:find("\n", 1, true)
			if not nl then
				break
			end
			local text = buf:sub(1, nl - 1)
			buf = buf:sub(nl + 1)
			if text:sub(1, 1) == "{" then
				I._dispatch(text)
			end
		end
		if #buf > MAX_LINE then
			buf = ""
			vim.notify("[gtm] oversized response discarded", vim.log.levels.WARN)
		end
	end)
end

function I._dispatch(text)
	local ok, data = pcall(vim.json.decode, text)
	local cb = ok and type(data) == "table" and data.id and pending[data.id]
	if not cb then
		return
	end
	pending[data.id] = nil
	vim.schedule(function()
		cb(data)
	end)
end

--- Fire a command. `params` is always on the wire, even when empty.
function I.send(cmd, params, callback)
	if not I.connected or not I.sock then
		if callback then
			vim.schedule(function()
				callback(nil, "not connected")
			end)
		end
		return
	end
	id = id + 1
	if callback then
		pending[id] = callback
	end
	I.sock:write(vim.json.encode({ id = id, cmd = cmd, params = params or {} }) .. "\n")
	return id
end

--- Adopt a `PlaybackStatus` payload: lowercase the two enums that arrive
--- PascalCase on the wire, then reset the extrapolation anchor.
function I.set_status(state)
	if not state then
		return
	end
	local s = denil(state)
	if type(s.status) == "string" then
		s.status = s.status:lower()
	end
	if type(s["repeat"]) == "string" then
		s["repeat"] = s["repeat"]:lower()
	end
	I.status = s
	base_pos, duration = s.time_pos or 0, s.duration or 0
	base_time, updated = hrtime(), hrtime()
end

-- Only these three move the status clock; everything else on the pulse stream
-- is a scalar patch or a theming signal.
local TRANSITION = { playback_started = "playing", playback_paused = "paused", playback_stopped = "stopped" }

--- Fold a playback transition into the snapshot and re-anchor the clock. A
--- partial event cannot blank the statusline: `current_track` is only replaced
--- when a real table arrives.
function I.apply(ev)
	local next_status = TRANSITION[ev.event]
	if not next_status then
		return
	end
	if ev.time_pos then
		base_pos = ev.time_pos
		duration = ev.duration or duration
	elseif ev.event == "playback_stopped" then
		base_pos, duration = 0, 0
	end
	base_time, updated = hrtime(), hrtime()
	if not I.status then
		return
	end
	I.status.status = next_status
	I.status.time_pos, I.status.duration = base_pos, duration
	if ev.track then
		I.status.current_track = ev.track
	elseif ev.event == "playback_stopped" then
		I.status.current_track = nil
	end
end

--- Fold a scalar off an event into the snapshot. Only called for fields that
--- exist to keep the statusline honest.
function I.patch(key, value)
	if I.status then
		I.status[key] = value
		updated = hrtime()
	end
end

function I.playing()
	return I.status ~= nil and I.status.status == "playing"
end

--- Position in seconds, advanced locally from the last transition.
function I.position()
	local pos = base_pos
	if I.playing() then
		pos = pos + (hrtime() - base_time) / 1e9
	end
	return math.max(0, duration > 0 and math.min(pos, duration) or pos)
end

function I.duration()
	return duration
end

--- Seconds since the snapshot last moved. 0 when it never has.
function I.stale_for()
	return updated > 0 and (hrtime() - updated) / 1e9 or 0
end

return I
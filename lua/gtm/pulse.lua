-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.pulse: subscriber to the gtmd pulse event stream
--
-- gtmd pushes state changes on a second Unix socket as length-prefixed
-- MessagePack frames: `[4-byte big-endian length][array of events]`, each event
-- an array whose first element is the tag and whose rest are the variant's
-- fields in Rust declaration order.
--
-- Most frames are audio telemetry nobody wants (`spectrum_changed` at 60 Hz,
-- `waveform_changed` at 30 Hz, `position_changed` at 60 Hz). Decoding those
-- would burn time in the read callback forever for nothing, so on a
-- single-event frame the tag is peeked off the front with a few byte
-- comparisons and an unrecognised one is dropped without ever being decoded.
-- `vim.mpack` — bundled with Neovim — does the decoding for what survives.
--
-- A frame may batch several events, and gtmd does exactly that for the theme:
-- `reactive_palette` and `reactive_theme` travel together. The peek only sees
-- the first tag, so batches are always decoded — dropping one on its leading
-- tag would throw away events that follow it. See `P._frame`.
--
-- This is free software released under the GPL-3.0 license.

local P = {}
local uv = vim.uv
local byte, sub = string.byte, string.sub

local sock, buf, heartbeat, handlers, connected = nil, "", 0, {}, false

-- Reconnection is owned here, not by the command socket: a pulse stream that
-- dies on its own has to come back without a Neovim restart.
local path, retry_timer, delay, watchdog, connected_at = nil, nil, 500, nil, 0

-- TrackInfo fields we read, in Rust declaration order. The tuple encoding drops
-- the names, so positions have to be re-keyed by hand; the remaining fields the
-- daemon sends past these are simply not read.
local TRACK_FIELDS = { "id", "path", "title", "artist", "album", "duration", "hash", "favourite" }

-- Field names per event, in variant declaration order. Tags not listed here
-- carry no fields. Everything absent from WANTED is TUI-only or telemetry.
local EVENT_FIELDS = {
	playback_started = { "track", "auto_advanced", "time_pos", "duration" },
	playback_paused = { "time_pos" },
	volume_changed = { "volume" },
	shuffle_changed = { "enabled" },
	repeat_mode_changed = { "mode" },
	-- Resolved role sets from a daemon new enough to send them. The two maps
	-- arrive as MessagePack maps, which `vim.mpack` decodes into tables.
	reactive_theme = { "ver", "dark", "light" },
}

local WANTED = {
	playback_started = true,
	playback_paused = true,
	playback_stopped = true,
	track_ended = true,
	volume_changed = true,
	shuffle_changed = true,
	repeat_mode_changed = true,
	reactive_theme = true,
	-- Not decoded for content, only liveness: a silent pulse stream is the
	-- symptom of a daemon that is up but not serving.
	heartbeat = true,
}

-- A frame this large is corrupt; drop the buffer and wait for the next read.
-- Far beyond any real event, and a cheap guard against desynchronising on it.
local MAX_FRAME = 16 * 1024 * 1024

-- gtmd beats every 15s. Anything past a minute means the stream is wedged even
-- though the socket still looks open — the same threshold `gtm.health` reports.
local HEARTBEAT_STALE = 60
local RETRY_MAX_DELAY = 10000

--- Position just past an array header, or nil if there is not one there.
local function past_array_header(s, pos)
	local m = byte(s, pos)
	if m >= 0x90 and m <= 0x9f then
		return pos + 1
	elseif m == 0xdc or m == 0xdd then
		return pos + (m == 0xdc and 3 or 5)
	end
	return nil
end

--- Tag of the first event in a frame, without decoding it. A frame is
--- `[ [tag, ...fields] ]`: hop the outer array header, hop the inner one, and
--- the bytes that follow are the tag as a MessagePack string.
local function peek_tag(s)
	local pos = past_array_header(s, 1)
	pos = pos and past_array_header(s, pos)
	local m = pos and byte(s, pos)
	if not m then
		return nil
	end
	local at, len
	if m >= 0xa0 and m <= 0xbf then
		at, len = pos + 1, m - 0xa0
	elseif m >= 0xd9 and m <= 0xdb then
		local width = m == 0xd9 and 1 or (m == 0xda and 2 or 4)
		len = 0
		for i = pos + 1, pos + width do
			len = len * 256 + byte(s, i)
		end
		at = pos + width + 1
	else
		return nil
	end
	return sub(s, at, at + len - 1)
end

function P.on(name, handler)
	handlers[name] = handlers[name] or {}
	table.insert(handlers[name], handler)
end

local function stop_timer(t)
	if t then
		t:stop()
		t:close()
	end
end

--- Drop the handle without forgetting where to reconnect.
local function teardown()
	if sock then
		sock:read_stop()
		if not sock:is_closing() then
			sock:close()
		end
		sock = nil
	end
	connected, buf = false, ""
	stop_timer(watchdog)
	watchdog = nil
end

--- Redial after a failure: exponential backoff, capped, one timer in flight.
local function retry_later()
	if retry_timer or not path then
		return
	end
	retry_timer = uv.new_timer()
	retry_timer:start(delay, 0, function()
		stop_timer(retry_timer)
		retry_timer = nil
		delay = math.min(delay * 2, RETRY_MAX_DELAY)
		P.connect(path)
	end)
end

--- Watchdog for a wedged stream. The command socket cannot see a pulse socket
--- that stopped delivering, so without this the editor sits on stale state until
--- Neovim restarts. `connected_at` is the floor until the first real beat, which
--- keeps a fresh connection from being mistaken for a silent one.
local function start_watchdog()
	stop_timer(watchdog)
	watchdog = uv.new_timer()
	watchdog:start(HEARTBEAT_STALE * 1000, HEARTBEAT_STALE * 1000, function()
		if sock and (uv.hrtime() - math.max(heartbeat, connected_at)) / 1e9 > HEARTBEAT_STALE then
			vim.schedule(function()
				if sock then
					teardown()
					retry_later()
				end
			end)
		end
	end)
end

--- Open the pulse socket. Safe to call repeatedly: a live socket is kept and a
--- dead one is replaced. Reconnection is claimed here rather than left to the
--- command socket, so a stream that dies on its own — a daemon restart, a
--- connect that lost a race with the listener — heals without a restart.
function P.connect(newpath)
	path = newpath or path
	if sock then
		if connected then
			return
		end
		teardown()
	end
	stop_timer(retry_timer)
	retry_timer = nil
	local pipe = uv.new_pipe(false)
	sock = pipe
	pipe:connect(path, function(err)
		if err or sock ~= pipe then
			if not pipe:is_closing() then
				pipe:close()
			end
			if sock == pipe then
				sock = nil
				retry_later()
			end
			return
		end
		connected, buf, connected_at = true, "", uv.hrtime()
		delay = 500
		pipe:read_start(function(rerr, data)
			if rerr or not data then
				if sock == pipe then
					teardown()
					retry_later()
				end
				return
			end
			buf = buf .. data
			while #buf >= 4 do
				local len = byte(buf, 1) * 16777216 + byte(buf, 2) * 65536 + byte(buf, 3) * 256 + byte(buf, 4)
				if len > MAX_FRAME then
					buf = ""
					break
				elseif #buf < len + 4 then
					break
				end
				local payload = sub(buf, 5, len + 4)
				buf = sub(buf, len + 5)
				P._frame(payload)
			end
		end)
		start_watchdog()
	end)
end

--- Tear the stream down for good: no watchdog, no retry. Used by `:Gtm`
--- teardown and `VimLeavePre`; the reconnect path calls `P.connect` instead.
function P.close()
	stop_timer(retry_timer)
	retry_timer = nil
	teardown()
	path = nil
end

function P.is_connected()
	return connected
end

--- Seconds since the last heartbeat, or nil if none has arrived. gtmd sends
--- them continuously, so a stale one means the daemon is gone or wedged.
function P.heartbeat_age()
	return heartbeat > 0 and (uv.hrtime() - heartbeat) / 1e9 or nil
end

--- Number of events a frame carries, read off its outer array header. 0 when
--- the first byte is not an array header at all, which means malformed.
local function event_count(s)
	local m = byte(s, 1)
	if not m then
		return 0
	elseif m >= 0x90 and m <= 0x9f then
		return m - 0x90
	elseif m == 0xdc then
		return byte(s, 2) * 256 + byte(s, 3)
	elseif m == 0xdd then
		return byte(s, 2) * 16777216 + byte(s, 3) * 65536 + byte(s, 4) * 256 + byte(s, 5)
	end
	return 0
end

function P._frame(payload)
	local n = event_count(payload)
	if n == 0 then
		return
	end
	-- The cheap reject applies to single events only, which is every frame the
	-- daemon batches nothing onto and therefore all of the 60 Hz telemetry. A
	-- batch is decoded in full so a wanted event trailing an unwanted one —
	-- `reactive_theme` behind `reactive_palette` — still reaches its handler.
	local tag = n == 1 and peek_tag(payload)
	if tag then
		if not WANTED[tag] then
			return
		elseif tag == "heartbeat" then
			heartbeat = uv.hrtime()
			return
		end
	end
	local ok, decoded = pcall(vim.mpack.decode, payload)
	if not ok or type(decoded) ~= "table" then
		return -- malformed frame: drop it, the framing already resynced
	end
	for _, raw in ipairs(decoded) do
		if type(raw) == "table" then
			P._emit(raw)
		end
	end
end

function P._emit(raw)
	local name, listeners = raw[1], handlers[raw[1]]
	if type(name) ~= "string" or not listeners then
		return
	end
	local ev = { event = name }
	for i, field in ipairs(EVENT_FIELDS[name] or {}) do
		-- mpack decodes null as vim.NIL; turn it back into a real nil.
		ev[field] = raw[i + 1] ~= vim.NIL and raw[i + 1] or nil
	end
	if type(ev.track) == "table" then
		local t = {}
		for i, field in ipairs(TRACK_FIELDS) do
			t[field] = ev.track[i] ~= vim.NIL and ev.track[i] or nil
		end
		ev.track = t
	end
	for _, listener in ipairs(listeners) do
		vim.schedule(function()
			listener(ev)
		end)
	end
end

return P
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
-- would burn time in the read callback forever for nothing, so the tag is
-- peeked off the front of the frame with a few byte comparisons and anything
-- unrecognised is dropped without ever being decoded. `vim.mpack` — bundled
-- with Neovim — does the decoding for the frames that survive.
--
-- This is free software released under the GPL-3.0 license.

local P = {}
local uv = vim.uv
local byte, sub = string.byte, string.sub

P.connected = false

local sock, buf, heartbeat, handlers = nil, "", 0, {}

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
	duration_changed = { "duration" },
	radio_title_changed = { "title" },
	reactive_palette = { "primary", "secondary", "tertiary" },
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
	duration_changed = true,
	radio_title_changed = true,
	reactive_palette = true,
	reactive_theme = true,
	-- Not decoded for content, only liveness: a silent pulse stream is the
	-- symptom of a daemon that is up but not serving.
	heartbeat = true,
}

-- A frame this large is corrupt; drop the buffer and wait for the next read.
-- Far beyond any real event, and a cheap guard against desynchronising on it.
local MAX_FRAME = 16 * 1024 * 1024

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

--- Open the pulse socket. Safe to call repeatedly: a live socket is kept, and
--- reconnection is the command socket's job (see `ipc._on_connect`).
function P.connect(path)
	if sock then
		return
	end
	local pipe = uv.new_pipe(false)
	sock = pipe
	pipe:connect(path, function(err)
		if err or sock ~= pipe then
			pipe:close()
			sock = nil
			return
		end
		P.connected, buf = true, ""
		pipe:read_start(function(rerr, data)
			if rerr or not data then
				P.connected = false
				P.close()
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
	end)
end

function P.close()
	if sock then
		sock:read_stop()
		sock:close()
		sock = nil
	end
	P.connected, buf = false, ""
end

function P.is_connected()
	return P.connected
end

--- Seconds since the last heartbeat, or nil if none has arrived. gtmd sends
--- them continuously, so a stale one means the daemon is gone or wedged.
function P.heartbeat_age()
	return heartbeat > 0 and (uv.hrtime() - heartbeat) / 1e9 or nil
end

function P._frame(payload)
	local tag = peek_tag(payload)
	if not tag or not WANTED[tag] then
		return
	end
	if tag == "heartbeat" then
		heartbeat = uv.hrtime()
		return
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
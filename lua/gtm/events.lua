-- Copyright (c) 2025 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.events: subscriber to the gtmd pulse event stream
--
-- gtmd exposes a second Unix socket (`gtmd.pulse`) that pushes every
-- `DaemonEvent` as a length-prefixed MessagePack frame:
--
--   [4-byte big-endian length][msgpack of [event]]
--
-- with each event encoded in rmp-serde StructTuple mode: an array whose first
-- element is the event tag, followed by the variant's fields in Rust
-- declaration order. `["volume_changed", 33]`, `["playback_started",
-- <track tuple>, false, 0.0, 0.0]`, etc.
--
-- Most frames are high-frequency audio telemetry (`spectrum_changed` at 60 Hz,
-- `waveform_changed` at 30 Hz, `position_changed` at 60 Hz) that no UI needs.
-- Instead of decoding every frame we peek only the leading tag (the frame
-- length already tells us where the frame ends) and discard unwanted frames in
-- O(1) — a decode would allocate thousands of tables per second.
--
-- Handlers are plain functions receiving a normalized event table (keyed by
-- field name; TrackInfo tuples are rebuilt into keyed track tables),
-- registered via `events.on(name, fn)` and dispatched through `vim.schedule`
-- so callback code is always on the main loop. The module owns no reconnect
-- policy: the command-socket reconnection path in `gtm.init` re-calls
-- `connect()`.
--
-- This is free software released under the GPL-3.0 license.

local E = {}

local uv = vim.uv
local msgpack = require("gtm.msgpack")

-- Events the plugin actually consumes. Everything else is dropped by tag
-- before any decode. `spectrum_changed` / `waveform_changed` /
-- `position_changed` / `queue_changed` / `sleep_timer_tick` / `custom` are
-- intentionally absent: the statusline resync and the 30 s `get_status_lite`
-- refresh cover liveness instead.
local WANTED = {
	playback_started = true,
	playback_paused = true,
	playback_stopped = true,
	track_ended = true,
	volume_changed = true,
	shuffle_changed = true,
	repeat_mode_changed = true,
	duration_changed = true,
	mono_changed = true,
	radio_title_changed = true,
	metadata_changed = true,
	heartbeat = true,
}

-- TrackInfo field names in Rust declaration order (gtm/src/shared/track.rs).
-- StructTuple encoding drops the names, so positions must be re-keyed.
local TRACK_FIELDS = {
	"id",
	"path",
	"title",
	"artist",
	"album",
	"duration",
	"actual_duration",
	"track_number",
	"genre",
	"year",
	"bitrate",
	"samplerate",
	"hash",
	"cover_path",
	"album_id",
	"favourite",
	"loudness_lufs",
	"loudness_peak_db",
	"loudness_range",
	"artist_image",
	"cover_url",
}

-- Field names per wanted event, in variant declaration order
-- (gtm/src/shared/ipc.rs). Event tags not listed here are unit variants.
local EVENT_FIELDS = {
	playback_started = { "track", "auto_advanced", "time_pos", "duration" },
	playback_paused = { "time_pos" },
	volume_changed = { "volume" },
	shuffle_changed = { "enabled" },
	repeat_mode_changed = { "mode" },
	duration_changed = { "duration" },
	mono_changed = { "enabled" },
	radio_title_changed = { "title" },
	metadata_changed = { "detail" },
}

local function normalize_track(raw)
	if type(raw) ~= "table" then
		return raw
	end
	local t = {}
	for i, name in ipairs(TRACK_FIELDS) do
		t[name] = raw[i]
	end
	return t
end

local function normalize_event(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local name = raw[1]
	if type(name) ~= "string" then
		return nil
	end
	local ev = { event = name }
	local fields = EVENT_FIELDS[name]
	if fields then
		for i, fname in ipairs(fields) do
			ev[fname] = raw[i + 1]
		end
	end
	if name == "playback_started" then
		ev.track = normalize_track(ev.track)
	end
	return ev
end

-- A frame that large is corrupt; drop the read buffer and wait for the next
-- unwindowed read. 16 MiB is far beyond any real event (the biggest, queue
-- or spectrum payloads, top out in the low megabytes).
local MAX_FRAME = 16 * 1024 * 1024

E._handlers = {}
E._sock = nil
E._buf = ""
E._connected = false
E._path = nil
E._last_heartbeat = 0

--- Register a handler for one event name (see `WANTED`).
function E.on(event_name, handler)
	if not E._handlers[event_name] then
		E._handlers[event_name] = {}
	end
	table.insert(E._handlers[event_name], handler)
end

function E.is_connected()
	return E._connected
end

function E.last_heartbeat()
	return E._last_heartbeat
end

--- Open the pulse socket. Safe to call repeatedly; a live socket is kept.
function E.connect(path)
	E._path = path
	if E._sock then
		return
	end
	E._sock = uv.new_pipe(false)
	E._sock:connect(path, function(err)
		if err then
			E._close_sock()
			return
		end
		E._connected = true
		E._buf = ""
		E._read_loop()
	end)
end

--- Close the pulse socket (used on shutdown; reconnects go through connect()).
function E.disconnect()
	E._connected = false
	E._close_sock()
	E._buf = ""
end

function E._close_sock()
	if E._sock then
		E._sock:read_stop()
		E._sock:close()
		E._sock = nil
	end
end

function E._read_loop()
	E._sock:read_start(function(err, data)
		if err or not data then
			E._connected = false
			E._close_sock()
			return
		end
		E._buf = E._buf .. data
		while #E._buf >= 4 do
			local b1, b2, b3, b4 = E._buf:byte(1, 4)
			local len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
			if len > MAX_FRAME then
				E._buf = ""
				break
			end
			local total = 4 + len
			if #E._buf < total then
				break
			end
			local payload = E._buf:sub(5, total)
			E._buf = E._buf:sub(total + 1)
			E._handle_frame(payload)
		end
	end)
end

function E._handle_frame(payload)
	local name = msgpack.peek_event(payload)
	if not name or not WANTED[name] then
		return -- O(1) drop, no allocation
	end
	if name == "heartbeat" then
		E._last_heartbeat = uv.hrtime()
	end
	local ok, value = pcall(msgpack.decode, payload)
	if not ok or type(value) ~= "table" then
		return -- malformed frame: skip silently, keep the stream in sync
	end
	for _, raw in ipairs(value) do
		local ev = normalize_event(raw)
		if ev then
			local handlers = E._handlers[ev.event]
			if handlers then
				for _, h in ipairs(handlers) do
					vim.schedule(function()
						h(ev)
					end)
				end
			end
		end
	end
end

return E

-- Copyright (c) 2025 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.msgpack: minimal MessagePack decoder for the gtmd event stream
--
-- gtmd pushes events on the `gtmd.pulse` sidecar socket as 4-byte-length-
-- prefixed MessagePack frames (rmp-serde 1.3.1 / rmp 0.8.15). The serializer
-- runs in StructTuple mode, so a `Vec<DaemonEvent>` encodes as an array of
-- arrays, each event being `[tag, field values in declaration order]`:
--
--   heartbeat            -> ["heartbeat"]
--   volume_changed       -> ["volume_changed", 33]
--   repeat_mode_changed  -> ["repeat_mode_changed", "One"]
--
-- Structs (TrackInfo inside `playback_started`) encode the same way. Frames
-- use compact integer encodings only — rmp's `write_sint` never emits ext
-- types — so this decoder covers nil, booleans, signed/unsigned ints, floats,
-- strings, binary, arrays and maps. Ext markers (0xc7-0xc9, 0xd4-0xd8) raise
-- an error so the caller can discard the frame instead of desynchronising the
-- reader; `skip` tolerates them so a mixed stream stays seekable.
--
-- This is free software released under the GPL-3.0 license.

local M = {}

local byte = string.byte
local sub = string.sub
local floor = math.floor

local function fail(pos)
	error("msgpack: malformed frame at byte " .. tostring(pos), 0)
end

local function guard(s, pos, n)
	if pos + n - 1 > #s then
		fail(pos)
	end
end

local function len8(s, pos)
	guard(s, pos, 1)
	return byte(s, pos), pos + 1
end

local function len16(s, pos)
	guard(s, pos, 2)
	local a, b = byte(s, pos, pos + 1)
	return a * 256 + b, pos + 2
end

local function len32(s, pos)
	guard(s, pos, 4)
	local a, b, c, d = byte(s, pos, pos + 3)
	return a * 16777216 + b * 65536 + c * 256 + d, pos + 4
end

--- Single-precision IEEE 754 from big-endian bytes.
local function f32(s, pos)
	guard(s, pos, 4)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local bits = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
	local sign = bits >= 0x80000000 and -1 or 1
	local exp = floor(bits / 0x800000) % 256
	local mant = bits % 0x800000
	if exp == 0 then
		return sign * mant * 2 ^ -149, pos + 4
	elseif exp == 255 then
		if mant == 0 then
			return sign * math.huge, pos + 4
		end
		return 0 / 0, pos + 4 -- nan
	end
	return sign * (1 + mant / 0x800000) * 2 ^ (exp - 127), pos + 4
end

--- Double-precision IEEE 754 from big-endian bytes.
local function f64(s, pos)
	guard(s, pos, 8)
	local h1, h2, h3, h4, l1, l2, l3, l4 = byte(s, pos, pos + 7)
	local hi = h1 * 16777216 + h2 * 65536 + h3 * 256 + h4
	local lo = l1 * 16777216 + l2 * 65536 + l3 * 256 + l4
	local sign = hi >= 0x80000000 and -1 or 1
	local exp = floor(hi / 0x100000) % 2048
	local mant_hi = hi % 0x100000
	if exp == 0 then
		return sign * (mant_hi * 4294967296 + lo) * 2 ^ -1074, pos + 8
	elseif exp == 2047 then
		if mant_hi == 0 and lo == 0 then
			return sign * math.huge, pos + 8
		end
		return 0 / 0, pos + 8 -- nan
	end
	return sign * (1 + (mant_hi * 4294967296 + lo) / 2 ^ 52) * 2 ^ (exp - 1023), pos + 8
end

--- 64-bit two's-complement int. Lua numbers lose precision past 2^53, which
--- is fine: every i64 the daemon emits (track ids, counts, timestamps) is
--- small or already approximated by the compact encodings — the i64/u64
--- markers only carry magnitudes that exceed double precision anyway.
local function i64(s, pos)
	guard(s, pos, 8)
	local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, pos, pos + 7)
	local u = b1 * 2 ^ 56 + b2 * 2 ^ 48 + b3 * 2 ^ 40 + b4 * 2 ^ 32 + b5 * 2 ^ 24 + b6 * 2 ^ 16 + b7 * 256 + b8
	if b1 >= 0x80 then
		return u - 2 ^ 64, pos + 8
	end
	return u, pos + 8
end

local function u64(s, pos)
	guard(s, pos, 8)
	local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, pos, pos + 7)
	return b1 * 2 ^ 56 + b2 * 2 ^ 48 + b3 * 2 ^ 40 + b4 * 2 ^ 32 + b5 * 2 ^ 24 + b6 * 2 ^ 16 + b7 * 256 + b8, pos + 8
end

local function read_bytes(s, pos, n)
	guard(s, pos, n)
	return sub(s, pos, pos + n - 1), pos + n
end

local decode_at -- forward declaration

local function decode_array(s, pos, n)
	-- nil values cannot be stored in a Lua table (assigning nil removes the
	-- element and `table.insert(t, nil)` no-ops), so holes are left absent:
	-- `t[i]` reads nil for them while `t.n` preserves the true length. Callers
	-- must read by position (raw[i]), never via `#raw` or `ipairs`.
	local t = { n = n }
	for i = 1, n do
		local v, next_pos = decode_at(s, pos)
		pos = next_pos
		if v ~= nil then
			t[i] = v
		end
	end
	return t, pos
end

local function decode_map(s, pos, n)
	local t = {}
	for _ = 1, n do
		local k, v
		k, pos = decode_at(s, pos)
		v, pos = decode_at(s, pos)
		t[k] = v
	end
	return t, pos
end

decode_at = function(s, pos)
	local m = byte(s, pos)
	if not m then
		fail(pos)
	end
	if m <= 0x7f then
		return m, pos + 1
	end
	if m >= 0xe0 then
		return m - 256, pos + 1
	end
	if m >= 0xa0 and m <= 0xbf then
		return read_bytes(s, pos + 1, m - 0xa0)
	end
	if m >= 0x90 and m <= 0x9f then
		return decode_array(s, pos + 1, m - 0x90)
	end
	if m >= 0x80 and m <= 0x8f then
		return decode_map(s, pos + 1, m - 0x80)
	end
	if m == 0xc0 then
		return nil, pos + 1
	end
	if m == 0xc2 then
		return false, pos + 1
	end
	if m == 0xc3 then
		return true, pos + 1
	end
	if m == 0xc4 then
		local n
		n, pos = len8(s, pos + 1)
		return read_bytes(s, pos, n)
	end
	if m == 0xc5 then
		local n
		n, pos = len16(s, pos + 1)
		return read_bytes(s, pos, n)
	end
	if m == 0xc6 then
		local n
		n, pos = len32(s, pos + 1)
		return read_bytes(s, pos, n)
	end
	if m == 0xca then
		return f32(s, pos + 1)
	end
	if m == 0xcb then
		return f64(s, pos + 1)
	end
	if m == 0xcc then
		local n, p = len8(s, pos + 1)
		return n, p
	end
	if m == 0xcd then
		local n, p = len16(s, pos + 1)
		return n, p
	end
	if m == 0xce then
		local n, p = len32(s, pos + 1)
		return n, p
	end
	if m == 0xcf then
		return u64(s, pos + 1)
	end
	if m == 0xd0 then
		local v = byte(s, pos + 1)
		if not v then
			fail(pos)
		end
		if v >= 0x80 then
			v = v - 256
		end
		return v, pos + 2
	end
	if m == 0xd1 then
		local a, b = byte(s, pos + 1, pos + 2)
		if not b then
			fail(pos)
		end
		local v = a * 256 + b
		if v >= 0x8000 then
			v = v - 65536
		end
		return v, pos + 3
	end
	if m == 0xd2 then
		local a, b, c, d = byte(s, pos + 1, pos + 4)
		if not d then
			fail(pos)
		end
		local v = a * 16777216 + b * 65536 + c * 256 + d
		if v >= 0x80000000 then
			v = v - 4294967296
		end
		return v, pos + 5
	end
	if m == 0xd3 then
		return i64(s, pos + 1)
	end
	if m == 0xd9 then
		local n
		n, pos = len8(s, pos + 1)
		return read_bytes(s, pos, n)
	end
	if m == 0xda then
		local n
		n, pos = len16(s, pos + 1)
		return read_bytes(s, pos, n)
	end
	if m == 0xdb then
		local n
		n, pos = len32(s, pos + 1)
		return read_bytes(s, pos, n)
	end
	if m == 0xdc then
		local n
		n, pos = len16(s, pos + 1)
		return decode_array(s, pos, n)
	end
	if m == 0xdd then
		local n
		n, pos = len32(s, pos + 1)
		return decode_array(s, pos, n)
	end
	if m == 0xde then
		local n
		n, pos = len16(s, pos + 1)
		return decode_map(s, pos, n)
	end
	if m == 0xdf then
		local n
		n, pos = len32(s, pos + 1)
		return decode_map(s, pos, n)
	end
	-- ext (0xc7-0xc9, 0xd4-0xd8) and 0xc1 are unsupported: reject loudly so
	-- a future protocol change surfaces instead of silently misparsing.
	fail(pos)
end

local skip_at -- forward declaration

local function skip_array(s, pos, n)
	for _ = 1, n do
		pos = skip_at(s, pos)
	end
	return pos
end

local function skip_map(s, pos, n)
	for _ = 1, n * 2 do
		pos = skip_at(s, pos)
	end
	return pos
end

skip_at = function(s, pos)
	local m = byte(s, pos)
	if not m then
		fail(pos)
	end
	if m <= 0x7f or m >= 0xe0 then
		return pos + 1
	end
	if m >= 0xa0 and m <= 0xbf then
		return pos + 1 + (m - 0xa0)
	end
	if m >= 0x90 and m <= 0x9f then
		return skip_array(s, pos + 1, m - 0x90)
	end
	if m >= 0x80 and m <= 0x8f then
		return skip_map(s, pos + 1, m - 0x80)
	end
	if m == 0xc0 or m == 0xc2 or m == 0xc3 then
		return pos + 1
	end
	if m == 0xc4 then
		local n, p = len8(s, pos + 1)
		return p + n
	end
	if m == 0xc5 then
		local n, p = len16(s, pos + 1)
		return p + n
	end
	if m == 0xc6 then
		local n, p = len32(s, pos + 1)
		return p + n
	end
	if m == 0xc7 then
		local n, p = len8(s, pos + 1)
		return p + 1 + n -- ext: type byte + payload
	end
	if m == 0xc8 then
		local n, p = len16(s, pos + 1)
		return p + 1 + n
	end
	if m == 0xc9 then
		local n, p = len32(s, pos + 1)
		return p + 1 + n
	end
	if m == 0xca then
		return pos + 5
	end
	if m == 0xcb then
		return pos + 9
	end
	if m == 0xcc or m == 0xd0 then
		return pos + 2
	end
	if m == 0xcd or m == 0xd1 then
		return pos + 3
	end
	if m == 0xce or m == 0xd2 then
		return pos + 5
	end
	if m == 0xcf or m == 0xd3 then
		return pos + 9
	end
	if m >= 0xd4 and m <= 0xd8 then
		local sizes = { 2, 3, 5, 9, 17 }
		return pos + sizes[m - 0xd3]
	end
	if m == 0xd9 then
		local n, p = len8(s, pos + 1)
		return p + n
	end
	if m == 0xda then
		local n, p = len16(s, pos + 1)
		return p + n
	end
	if m == 0xdb then
		local n, p = len32(s, pos + 1)
		return p + n
	end
	if m == 0xdc then
		local n, p = len16(s, pos + 1)
		return skip_array(s, p, n)
	end
	if m == 0xdd then
		local n, p = len32(s, pos + 1)
		return skip_array(s, p, n)
	end
	if m == 0xde then
		local n, p = len16(s, pos + 1)
		return skip_map(s, p, n)
	end
	if m == 0xdf then
		local n, p = len32(s, pos + 1)
		return skip_map(s, p, n)
	end
	fail(pos)
end

--- Decode a complete MessagePack value starting at `pos` (default 1).
--- Arrays decode to tables with a `.n` length key: nil elements are absent
--- keys (read as nil at their position), so use `raw[i]` + `raw.n`, never
--- `#raw`/`ipairs` on arrays that may contain nil.
--- @return the value, the next byte position
function M.decode(s, pos)
	local v, next_pos = decode_at(s, pos or 1)
	return v, next_pos
end

--- Skip one value starting at `pos`, returning the next byte position.
function M.skip(s, pos)
	return skip_at(s, pos or 1)
end

--- Read only the leading event tag of a pulse frame without decoding the
--- rest. A frame is `[ ["event_name", ...fields] ]` (Vec of StructTuple-mode
--- events); serde writes the internally-tagged `event` value first, but we
--- verify the outer array and inner array shapes instead of trusting that.
--- @return string|nil the event name of the first event in the frame
function M.peek_event(s)
	local p = 1
	local m = byte(s, p)
	if not m then
		return nil
	end
	-- outer array (the Vec<DaemonEvent>)
	if m >= 0x90 and m <= 0x9f then
		p = p + 1
	elseif m == 0xdc then
		local n
		n, p = len16(s, p + 1)
		if n == 0 then
			return nil
		end
	elseif m == 0xdd then
		local n
		n, p = len32(s, p + 1)
		if n == 0 then
			return nil
		end
	else
		return nil
	end
	-- inner array (one event: [tag, ...fields])
	local m2 = byte(s, p)
	if not m2 then
		return nil
	end
	if m2 >= 0x90 and m2 <= 0x9f then
		p = p + 1
	elseif m2 == 0xdc then
		local n
		n, p = len16(s, p + 1)
		if n == 0 then
			return nil
		end
	elseif m2 == 0xdd then
		local n
		n, p = len32(s, p + 1)
		if n == 0 then
			return nil
		end
	else
		return nil
	end
	local ok, value = pcall(decode_at, s, p)
	if not ok or type(value) ~= "string" then
		return nil
	end
	return value
end

return M

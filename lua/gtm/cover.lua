-- Copyright (c) 2025 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.cover: cover-art cache, sniffing, and local-file fallbacks
--
-- Covers flow daemon -> plugin like this: `get_cover_art` returns a base64
-- blob on the command socket; we decode it, sniff its file signature, and
-- store it under the plugin's own cache directory keyed by track hash, so a
-- flat 500-file directory is never scanned. `fetch()` owns the full
-- resolution order:
--
--   1. plugin cache (hash-derived key)
--   2. daemon `get_cover_art` payload
--   3. `track.cover_path` / `cover.jpg`-style sidecars next to the audio file
--
-- The plugin cache lives in `stdpath("cache")/gtm/cover`. It is deliberately
-- separate from the daemon's own cache (`~/.cache/gtm/covers`): `cleanup()`
-- must never be able to touch the daemon's directory.
--
-- This module is pure (no init.lua dependency): the daemon fetcher is injected
-- as a callback so `gtm.init` wires it to its IPC layer.
--
-- This is free software released under the GPL-3.0 license.

local C = {}

C._dir = nil
C._pending = {}

--- Whether image.nvim is available for on-screen rendering.
function C.available()
	local ok, image = pcall(require, "image")
	return ok and image ~= nil
end

--- Cache directory (created on first access).
function C.dir()
	if not C._dir then
		local dir = vim.fn.stdpath("cache") .. "/gtm/cover"
		if vim.fn.isdirectory(dir) == 0 then
			vim.fn.mkdir(dir, "p")
		end
		C._dir = dir
	end
	return C._dir
end

--- Stable per-track cache key: hash when present, else a path digest.
function C.key(track)
	if not track or type(track) ~= "table" then
		return nil
	end
	local hash = track.hash
	if hash and hash ~= "" then
		return hash
	end
	local path = track.path
	if path and path ~= "" then
		return (vim.fn.sha256(path):sub(1, 16))
	end
	return nil
end

local MAGIC = {
	{ "\xff\xd8\xff", "jpg" },
	{ "\x89PNG\r\n\x1a\n", "png" },
	{ "GIF8", "gif" },
	{ "BM", "bmp" },
}

--- Guess the image extension from magic bytes; defaults to jpg.
function C.sniff(bytes)
	if not bytes or #bytes < 4 then
		return "jpg"
	end
	for _, m in ipairs(MAGIC) do
		if bytes:sub(1, #m[1]) == m[1] then
			return m[2]
		end
	end
	if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
		return "webp"
	end
	return "jpg"
end

local KNOWN_EXTS = { "jpg", "jpeg", "png", "webp", "gif", "bmp" }

function C.path_for(key, ext)
	return C.dir() .. "/" .. key .. "." .. (ext or "jpg")
end

--- First cached copy of the artwork for `key`, or nil.
function C.cached(key)
	if not key then
		return nil
	end
	for _, ext in ipairs(KNOWN_EXTS) do
		local p = C.path_for(key, ext)
		if vim.fn.filereadable(p) == 1 then
			return p
		end
	end
	return nil
end

--- Write decoded cover bytes and return the path. Binary strings can't cross
--- into VimL (they'd become a Blob, which writefile rejects), so the file is
--- written straight from Lua via io.
function C.store(key, ext, bytes)
	local p = C.path_for(key, ext)
	local f = io.open(p, "wb")
	if f then
		f:write(bytes)
		f:close()
	end
	return p
end

--- Local-artwork fallback: `track.cover_path` first, then conventional
--- sidecar names next to the audio file. Returns a path or nil.
function C.local_art(track)
	if not track or type(track) ~= "table" or not track.path or track.path == "" then
		return nil
	end
	local cover_path = track.cover_path
	if cover_path and cover_path ~= "" and vim.fn.filereadable(cover_path) == 1 then
		return cover_path
	end
	local dir = vim.fn.fnamemodify(track.path, ":h")
	local names = {
		"cover.jpg",
		"cover.jpeg",
		"cover.png",
		"cover.webp",
		"folder.jpg",
		"folder.jpeg",
		"folder.png",
		"front.jpg",
		"front.png",
		"album.jpg",
	}
	for _, name in ipairs(names) do
		local p = dir .. "/" .. name
		if vim.fn.filereadable(p) == 1 then
			return p
		end
	end
	return nil
end

--- Full resolution: cache -> daemon payload -> local sidecars.
--- `fetcher(track, done)` is injected (wired to `ipc.get_cover_art`); it must
--- call `done(base64_or_nil, err)`. Concurrent requests for the same key are
--- coalesced onto one daemon call.
function C.fetch(track, fetcher, cb)
	if not track or not cb or type(fetcher) ~= "function" then
		return
	end
	local key = C.key(track)
	if not key then
		cb(nil)
		return
	end
	local cached = C.cached(key)
	if cached then
		cb(cached)
		return
	end
	if C._pending[key] then
		table.insert(C._pending[key], cb)
		return
	end
	C._pending[key] = { cb }
	local function finish(path)
		local pend = C._pending[key]
		C._pending[key] = nil
		for _, c in ipairs(pend) do
			c(path)
		end
	end
	fetcher(track, function(b64, err)
		if b64 then
			local ok, bytes = pcall(vim.base64.decode, b64)
			if ok and bytes and #bytes > 0 and #bytes >= 16 then
				finish(C.store(key, C.sniff(bytes), bytes))
				return
			end
		end
		finish(C.local_art(track) or (err and nil))
	end)
end

--- Remove the plugin's own cache directory. The daemon's cache is never
--- touched by design (separate directory).
function C.cleanup()
	if C._dir and vim.fn.isdirectory(C._dir) == 1 then
		vim.fn.delete(C._dir, "rf")
	end
	C._dir = nil
end

return C

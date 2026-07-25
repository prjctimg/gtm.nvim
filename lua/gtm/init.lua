-- Copyright (c) 2025 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.nvim: Neovim wrapper for the GTM daemon via Unix socket IPC
--
-- This is free software released under the GPL-3.0 license.

local I = {}

local default_opts = {
	socket_path = nil,
	statusline_format = "compact",
	statusline_interval = 1000,
	float = {
		width = 0.8,
		height = 0.8,
		border = "rounded",
		cover_art = true,
	},
	keymaps = {
		play_pause = "<leader>gp",
		next = "<leader>gn",
		prev = "<leader>gN",
		volume_up = "<leader>g>",
		volume_down = "<leader>g<",
		float = "<leader>gf",
		stop = "<leader>gS",
	},
}

I.opts = vim.deepcopy(default_opts)

-- ============================================================================
-- IPC: Unix socket communication with gtmd
-- ============================================================================

local ipc = {
	_sock = nil,
	_sock_path = nil,
	last_status = nil,
	_connected = false,
	_base_pos = 0,
	_base_time = 0,
	_is_playing = false,
	_duration = 0,
	_buf = "",
	_cmd_id = 0,
	_pending_by_id = {},
}

local uv = vim.uv
local hrtime = uv.hrtime

local function resolve_socket_path()
	local runtime = os.getenv("XDG_RUNTIME_DIR")
	if runtime then
		local path = runtime .. "/gtm/gtmd.sock"
		if uv.fs_stat(path) then
			return path
		end
	end
	local user = os.getenv("USER") or "root"
	local tmp_fallback = "/tmp/gtm-" .. user .. "/gtm/gtmd.sock"
	if uv.fs_stat(tmp_fallback) then
		return tmp_fallback
	end
	local tmpdir = os.getenv("TMPDIR")
	if tmpdir then
		local path = tmpdir .. "/gtm/gtmd.sock"
		if uv.fs_stat(path) then
			return path
		end
	end
	local home = os.getenv("HOME") or "/tmp"
	return home .. "/.gtm/gtm/gtmd.sock"
end

local function resolve_pulse_socket_path()
	local base = resolve_socket_path():gsub("gtmd%.sock$", "gtmd.pulse")
	return base
end

function ipc.connect(path)
	ipc._sock_path = path or resolve_socket_path()
	ipc._sock = uv.new_pipe(false)
	ipc._sock:connect(ipc._sock_path, function(err)
		if err then
			ipc._connected = false
			vim.notify("[gtm] failed to connect: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		ipc._connected = true
		ipc._read_loop()
		ipc._send_handshake()
	end)
end

function ipc._send_handshake()
	ipc._cmd_id = 0
	local req = { id = 0, cmd = "handshake", version = 1, client = "gtm.nvim" }
	local payload = vim.json.encode(req) .. "\n"
	ipc._pending_by_id[0] = function(resp)
		if not resp.ok then
			vim.notify("[gtm] daemon rejected handshake: " .. (resp.error or "version mismatch"), vim.log.levels.ERROR)
			ipc.disconnect()
		end
	end
	ipc._sock:write(payload)
end

function ipc._read_loop()
	ipc._buf = ""
	ipc._sock:read_start(function(err, data)
		if err or not data then
			ipc._connected = false
			return
		end
		ipc._buf = ipc._buf .. data
		while #ipc._buf > 0 do
			local first = ipc._buf:sub(1, 1)
			if first == "{" or first == '"' then
				local nl = ipc._buf:find("\n", 1, true)
				if not nl then
					break
				end
				local line = ipc._buf:sub(1, nl - 1)
				ipc._buf = ipc._buf:sub(nl + 1)
				if #line > 0 then
					ipc._handle_json(line)
				end
			else
				if #ipc._buf < 4 then
					break
				end
				local b1, b2, b3, b4 = ipc._buf:byte(1, 4)
				local len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
				if len > 16 * 1024 * 1024 then
					ipc._buf = ""
					break
				end
				local total = 4 + len
				if #ipc._buf < total then
					break
				end
				ipc._buf = ipc._buf:sub(total + 1)
			end
		end
	end)
end

local _event_handlers = {}

function ipc.on_event(event_name, handler)
	if not _event_handlers[event_name] then
		_event_handlers[event_name] = {}
	end
	table.insert(_event_handlers[event_name], handler)
end

function ipc._handle_json(line)
	local ok, data = pcall(vim.json.decode, line)
	if not ok or type(data) ~= "table" then
		return
	end

	if data.event then
		local handlers = _event_handlers[data.event]
		if handlers then
			for _, handler in ipairs(handlers) do
				handler(data)
			end
		end
		return
	end

	if data.id and ipc._pending_by_id[data.id] then
		local cb = ipc._pending_by_id[data.id]
		ipc._pending_by_id[data.id] = nil
		vim.schedule(function()
			cb(data)
		end)
	end
end

ipc.on_event("playback_started", function(ev)
	ipc._base_pos = ev.time_pos or 0
	ipc._base_time = hrtime()
	ipc._is_playing = true
	ipc._duration = ev.duration or 0
	if ev.track then
		ipc.last_status = {
			status = "playing",
			volume = ipc.last_status and ipc.last_status.volume or 80,
			shuffle = ipc.last_status and ipc.last_status.shuffle or false,
			["repeat"] = ipc.last_status and ipc.last_status["repeat"] or "off",
			time_pos = ev.time_pos or 0,
			duration = ev.duration or 0,
			current_track = ev.track,
		}
	end
end)

ipc.on_event("playback_paused", function(ev)
	ipc._base_pos = ev.time_pos or ipc._base_pos
	ipc._base_time = hrtime()
	ipc._is_playing = false
	if ipc.last_status then
		ipc.last_status.status = "paused"
		ipc.last_status.time_pos = ev.time_pos or ipc._base_pos
	end
end)

ipc.on_event("playback_stopped", function()
	ipc._base_pos = 0
	ipc._is_playing = false
	if ipc.last_status then
		ipc.last_status.status = "stopped"
		ipc.last_status.time_pos = 0
	end
end)

ipc.on_event("position_changed", function(ev)
	ipc._base_pos = ev.time_pos or 0
	ipc._base_time = hrtime()
end)

ipc.on_event("duration_changed", function(ev)
	ipc._duration = ev.duration or 0
	if ipc.last_status then
		ipc.last_status.duration = ev.duration or 0
	end
end)

ipc.on_event("volume_changed", function(ev)
	if ipc.last_status then
		ipc.last_status.volume = ev.volume
	end
end)

ipc.on_event("shuffle_changed", function(ev)
	if ipc.last_status then
		ipc.last_status.shuffle = ev.enabled
	end
end)

ipc.on_event("repeat_mode_changed", function(ev)
	if ipc.last_status then
		ipc.last_status["repeat"] = ev.mode
	end
end)

ipc.on_event("heartbeat", function()
	ipc._last_heartbeat = hrtime()
end)

function ipc.send_cmd(cmd, params, callback)
	if not ipc._connected or not ipc._sock then
		if callback then
			vim.schedule(function()
				callback(nil, "not connected")
			end)
		end
		return
	end
	ipc._cmd_id = ipc._cmd_id + 1
	local req = { id = ipc._cmd_id, cmd = cmd }
	if params then
		for k, v in pairs(params) do
			req[k] = v
		end
	end
	local payload = vim.json.encode(req) .. "\n"
	if callback then
		ipc._pending_by_id[ipc._cmd_id] = callback
	end
	ipc._sock:write(payload)
	return ipc._cmd_id
end

function ipc.get_status(callback)
	if not callback then
		ipc.send_cmd("get_status")
		return
	end
	ipc.send_cmd("get_status", nil, function(resp)
		if resp and resp.state then
			local state = resp.state
			ipc.last_status = state
			ipc._base_pos = state.time_pos or 0
			ipc._base_time = hrtime()
			ipc._is_playing = state.status == "playing"
			ipc._duration = state.duration or 0
			callback(state)
		end
	end)
end

function ipc.disconnect()
	if ipc._sock then
		ipc._sock:read_stop()
		ipc._sock:close()
		ipc._sock = nil
	end
	ipc._connected = false
	ipc.last_status = nil
	ipc._pending_by_id = {}
end

function ipc.estimated_pos()
	local pos = ipc._base_pos or 0
	if ipc._is_playing then
		pos = pos + (hrtime() - ipc._base_time) / 1e9
	end
	local dur = ipc._duration or 0
	if dur > 0 then
		pos = math.min(pos, dur)
	end
	return math.max(0, pos)
end

-- ============================================================================
-- IPC: Library
-- ============================================================================

function ipc.library_get_tracks(filter, sort, callback)
	ipc.send_cmd("library", {
		action = {
			get_tracks = {
				filter = filter or nil,
				sort = sort or nil,
			},
		},
	}, function(resp)
		if callback and resp and resp.tracks then
			callback(resp.tracks)
		end
	end)
end

function ipc.library_get_playlists(callback)
	ipc.send_cmd("library", {
		action = "get_playlists",
	}, function(resp)
		if callback and resp and resp.playlists then
			callback(resp.playlists)
		end
	end)
end

function ipc.library_scan(path, callback)
	ipc.send_cmd("library", {
		action = {
			scan = { path = path },
		},
	}, function(resp)
		if callback and resp and resp.tracks then
			callback(resp.tracks)
		end
	end)
end

function ipc.library_create_playlist(name, callback)
	ipc.send_cmd("library", {
		action = {
			create_playlist = { name = name },
		},
	}, function(resp)
		if callback and resp and resp.playlists then
			callback(resp.playlists)
		end
	end)
end

function ipc.library_delete_playlist(id, callback)
	ipc.send_cmd("library", {
		action = {
			delete_playlist = { id = id },
		},
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.library_add_to_playlist(playlist_id, track_ids, callback)
	ipc.send_cmd("library", {
		action = {
			add_to_playlist = {
				playlist_id = playlist_id,
				track_ids = track_ids,
			},
		},
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.library_remove_from_playlist(playlist_id, track_id, callback)
	ipc.send_cmd("library", {
		action = {
			remove_from_playlist = {
				playlist_id = playlist_id,
				track_id = track_id,
			},
		},
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.library_remove_track(id, callback)
	ipc.send_cmd("library", {
		action = {
			remove_track = { id = id },
		},
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.library_get_recent(count, callback)
	ipc.send_cmd("library", {
		action = {
			get_recent = { count = count or 50 },
		},
	}, function(resp)
		if callback and resp and resp.tracks then
			callback(resp.tracks)
		end
	end)
end

-- ============================================================================
-- IPC: Favourites
-- ============================================================================

function ipc.get_favourites(callback)
	ipc.send_cmd("get_favourites", nil, function(resp)
		if callback and resp and resp.tracks then
			callback(resp.tracks)
		end
	end)
end

function ipc.add_favourite(track_id, callback)
	ipc.send_cmd("add_favourite", { track_id = track_id }, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.remove_favourite(track_id, callback)
	ipc.send_cmd("remove_favourite", { track_id = track_id }, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

-- ============================================================================
-- IPC: Equalizer
-- ============================================================================

function ipc.set_eq_preset(preset, callback)
	ipc.send_cmd("set_eq_preset", { preset = preset }, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.set_eq_enabled(enabled, callback)
	ipc.send_cmd("set_eq_enabled", { enabled = enabled }, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

-- ============================================================================
-- IPC: YouTube
-- ============================================================================

function ipc.yt_search(query, filter, callback)
	ipc.send_cmd("yt_search", {
		query = query,
		filter = filter or nil,
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.yt_search_poll(callback)
	ipc.send_cmd("yt_search_poll", nil, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.yt_search_cancel(callback)
	ipc.send_cmd("yt_search_cancel", nil, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.yt_resolve_stream(url, callback)
	ipc.send_cmd("yt_resolve_stream", { url = url }, function(resp)
		if callback and resp and resp.stream_info then
			callback(resp.stream_info)
		end
	end)
end

-- ============================================================================
-- IPC: Queue
-- ============================================================================

function ipc.queue_list(callback)
	ipc.send_cmd("queue", { action = "list" }, function(resp)
		if callback and resp and resp.queue_state then
			callback(resp.queue_state)
		end
	end)
end

function ipc.queue_clear(callback)
	ipc.send_cmd("queue", { action = "clear" }, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.queue_add(path, position, callback)
	ipc.send_cmd("queue", {
		action = {
			add = { path = path, position = position or nil },
		},
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.queue_remove(index, callback)
	ipc.send_cmd("queue", {
		action = {
			remove = { index = index },
		},
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.queue_move(from, to, callback)
	ipc.send_cmd("queue", {
		action = {
			move = { from = from, to = to },
		},
	}, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

-- ============================================================================
-- IPC: Playback extras
-- ============================================================================

function ipc.seek(position_secs, callback)
	ipc.send_cmd("seek", { position_secs = position_secs }, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.toggle_shuffle(callback)
	ipc.send_cmd("toggle_shuffle", nil, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.cycle_repeat(mode, callback)
	ipc.send_cmd("cycle_repeat", { mode = mode or "off" }, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

function ipc.toggle_mute(callback)
	ipc.send_cmd("toggle_mute", nil, function(resp)
		if callback then
			callback(resp)
		end
	end)
end

-- ============================================================================
-- Shared helpers: time formatting, progress bar, status icon
-- ============================================================================

local function fmt_time(secs)
	if not secs or secs < 0 then
		return "00:00"
	end
	local m = math.floor(secs / 60)
	local s = math.floor(secs % 60)
	return string.format("%02d:%02d", m, s)
end

local function progress(pos, dur, width)
	if dur <= 0 then
		return string.rep("━", width)
	end
	local pct = math.min(1.0, math.max(0, pos / dur))
	local filled = math.floor(pct * width)
	local empty = width - filled
	return string.rep("━", filled) .. string.rep("─", empty)
end

local function status_icon(s)
	if not s then
		return " "
	end
	if s.status == "playing" then
		return "▶"
	elseif s.status == "paused" then
		return "⏸"
	else
		return "⏹"
	end
end

-- ============================================================================
-- Cover Art: resolution, caching, image.nvim integration
-- ============================================================================

local coverart = {
	_cache_dir = nil,
}

function coverart._get_cache_dir()
	if not coverart._cache_dir then
		local data_dir = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
		coverart._cache_dir = data_dir .. "/gtm/covers"
		vim.fn.mkdir(coverart._cache_dir, "p")
	end
	return coverart._cache_dir
end

function coverart.available()
	local ok, image = pcall(require, "image")
	return ok and image ~= nil
end

function coverart.resolve(track_path, cover_art_field, callback)
	if not track_path or track_path == "" then
		callback(nil)
		return
	end

	if cover_art_field and cover_art_field ~= "" and vim.fn.filereadable(cover_art_field) == 1 then
		callback(cover_art_field)
		return
	end

	local dir = vim.fn.fnamemodify(track_path, ":h")
	local candidates = { "cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "front.png", "cover.jpeg", "folder.jpeg" }
	for _, name in ipairs(candidates) do
		local path = dir .. "/" .. name
		if vim.fn.filereadable(path) == 1 then
			callback(path)
			return
		end
	end

	local cache_dir = coverart._get_cache_dir()
	local hash = vim.fn.sha256(track_path):sub(1, 16)
	local cached = cache_dir .. "/" .. hash .. ".jpg"

	if vim.fn.filereadable(cached) == 1 then
		callback(cached)
		return
	end

	vim.fn.jobstart({
		"ffmpeg", "-i", track_path,
		"-an", "-vcodec", "mjpeg", "-frames:v", "1",
		"-y", cached,
	}, {
		on_exit = function(_, code)
			vim.schedule(function()
				if code == 0 and vim.fn.filereadable(cached) == 1 then
					callback(cached)
				else
					callback(nil)
				end
			end)
		end,
	})
end

function coverart.cleanup()
	if coverart._cache_dir then
		vim.fn.delete(coverart._cache_dir, "rf")
	end
end

-- ============================================================================
-- Float: native playback UI in a floating window
-- ============================================================================

local float = {
	win_id = nil,
	buf_id = nil,
	cover_win_id = nil,
	cover_buf_id = nil,
	_image = nil,
	_timer = nil,
	_last_track_path = nil,
}

function float.toggle(_opts)
	_opts = _opts or I.opts
	if float.win_id and vim.api.nvim_win_is_valid(float.win_id) then
		float.close()
		return
	end
	float.open(_opts)
end

function float.close()
	if float._image then
		float._image:clear()
		float._image = nil
	end

	if float.cover_win_id and vim.api.nvim_win_is_valid(float.cover_win_id) then
		vim.api.nvim_win_close(float.cover_win_id, true)
	end
	float.cover_win_id = nil
	float.cover_buf_id = nil

	float._stop_refresh_timer()

	if float.win_id and vim.api.nvim_win_is_valid(float.win_id) then
		vim.api.nvim_win_close(float.win_id, true)
	end
	float.win_id = nil
	float.buf_id = nil
	float._last_track_path = nil
end

function float.open(_opts)
	_opts = _opts or I.opts
	local float_cfg = _opts.float or {}
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines - vim.o.cmdheight
	local width = math.floor(editor_width * (float_cfg.width or 0.8))
	local height = math.floor(editor_height * (float_cfg.height or 0.8))
	local row = math.floor((editor_height - height) / 2)
	local col = math.floor((editor_width - width) / 2)

	float.buf_id = vim.api.nvim_create_buf(false, true)
	vim.bo[float.buf_id].buftype = "nofile"
	vim.bo[float.buf_id].bufhidden = "wipe"
	vim.bo[float.buf_id].filetype = "gtm"

	float.win_id = vim.api.nvim_open_win(float.buf_id, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		border = float_cfg.border or "rounded",
		title = " GTM ",
		title_pos = "center",
		style = "minimal",
	})

	if float_cfg.cover_art ~= false and coverart.available() then
		float._create_cover_window(width, height, float_cfg)
	end

	float._render()
	float._start_refresh_timer()

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = float.buf_id,
		once = true,
		callback = function()
			float._stop_refresh_timer()
			if float._image then
				float._image:clear()
				float._image = nil
			end
			if float.cover_win_id and vim.api.nvim_win_is_valid(float.cover_win_id) then
				vim.api.nvim_win_close(float.cover_win_id, true)
			end
			float.cover_win_id = nil
			float.cover_buf_id = nil
			float.win_id = nil
			float.buf_id = nil
			float._last_track_path = nil
		end,
	})

	float._setup_keymaps(_opts)
end

function float.is_open()
	return float.win_id ~= nil and vim.api.nvim_win_is_valid(float.win_id)
end

function float._create_cover_window(parent_width, parent_height, float_cfg)
	local cover_size = math.min(
		math.floor(parent_width * 0.35),
		math.floor(parent_height * 0.6),
		20
	)

	float.cover_buf_id = vim.api.nvim_create_buf(false, true)
	vim.bo[float.cover_buf_id].buftype = "nofile"
	vim.bo[float.cover_buf_id].bufhidden = "wipe"
	vim.bo[float.cover_buf_id].filetype = "gtm-cover"

	float.cover_win_id = vim.api.nvim_open_win(float.cover_buf_id, false, {
		relative = "editor",
		width = cover_size,
		height = cover_size,
		row = math.floor((vim.o.lines - vim.o.cmdheight - parent_height) / 2) + 2,
		col = math.floor((vim.o.columns - parent_width) / 2) + 2,
		border = float_cfg.border or "rounded",
		style = "minimal",
		focusable = false,
		zindex = 10,
	})
end

function float._render_cover(cover_path)
	if not coverart.available() or not cover_path then
		return
	end

	local image = require("image")

	if float._image then
		float._image:clear()
		float._image = nil
	end

	float._image = image.from_file(cover_path, {
		window = float.cover_win_id,
		buffer = float.cover_buf_id,
		id = "gtm_cover_art",
	})

	if float._image then
		float._image:render()
	end
end

function float._render()
	if not float.buf_id or not vim.api.nvim_buf_is_valid(float.buf_id) then
		return
	end

	local s = ipc.last_status
	local lines = {}

	if s and s.current_track then
		local t = s.current_track
		local artist = t.artist or "Unknown"
		local title = t.title or "Unknown"
		local album = t.album or ""
		local icon = status_icon(s)
		local vol = s.volume or 0
		local pos = ipc.estimated_pos()
		local dur = t.duration or 0

		table.insert(lines, "")
		if not (coverart.available() and float._image) then
			table.insert(lines, string.format("  %s  %s", icon, title))
			table.insert(lines, string.format("  by %s", artist))
			if album ~= "" then
				table.insert(lines, string.format("  on %s", album))
			end
		else
			table.insert(lines, string.format("  %s  %s", icon, title))
			table.insert(lines, string.format("  %s", artist))
			if album ~= "" then
				table.insert(lines, string.format("  %s", album))
			end
		end
		table.insert(lines, "")
		table.insert(lines, string.format("  %s / %s", fmt_time(pos), fmt_time(dur)))
		table.insert(lines, "  " .. progress(pos, dur, 30))
		table.insert(lines, string.format("  vol:%d%%", vol))
		if s.shuffle then
			table.insert(lines, "  shuffle on")
		end
		if s["repeat"] and s["repeat"] ~= "off" then
			table.insert(lines, "  repeat: " .. s["repeat"])
		end
		table.insert(lines, "")
		table.insert(lines, "  [Space] play/pause  [n] next  [p] prev  [-/+] vol  [q] close")
	else
		table.insert(lines, "")
		table.insert(lines, "  GTM - not playing")
		table.insert(lines, "")
		table.insert(lines, "  Press [q] to close")
	end

	vim.api.nvim_buf_set_lines(float.buf_id, 0, -1, false, lines)

	if s and s.current_track then
		local track = s.current_track
		local track_path = track.path or ""
		if track_path ~= float._last_track_path then
			float._last_track_path = track_path
			coverart.resolve(track_path, track.cover_art, function(path)
				vim.schedule(function()
					if float.is_open() then
						float._render_cover(path)
					end
				end)
			end)
		end
	end
end

function float._start_refresh_timer()
	float._stop_refresh_timer()
	float._timer = uv.new_timer()
	float._timer:start(0, 500, function()
		vim.schedule(function()
			if float.is_open() then
				float._render()
			else
				float._stop_refresh_timer()
			end
		end)
	end)
end

function float._stop_refresh_timer()
	if float._timer then
		float._timer:stop()
		float._timer:close()
		float._timer = nil
	end
end

function float._setup_keymaps(_opts)
	local km = {
		["<Space>"] = function() I.play_pause() end,
		["n"] = function() I.next() end,
		["p"] = function() I.prev() end,
		["+"] = function() I.volume_up() end,
		["-"] = function() I.volume_down() end,
		["s"] = function() I.stop() end,
		["q"] = function() float.toggle(_opts) end,
		["<Esc>"] = function() float.toggle(_opts) end,
	}
	for lhs, rhs in pairs(km) do
		vim.keymap.set("n", lhs, rhs, {
			buffer = float.buf_id,
			noremap = true,
			silent = true,
			desc = "GTM float",
		})
	end
end

-- ============================================================================
-- Statusline: compact and detailed renderers
-- ============================================================================

local statusline = {
	_timer = nil,
}

function statusline.compact(s)
	if not s or not s.current_track then
		return " "
	end
	local t = s.current_track
	local artist = t.artist or "Unknown"
	local title = t.title or "Unknown"
	local icon = status_icon(s)
	local vol = s.volume or 0
	local pos = ipc.estimated_pos()
	local dur = t.duration or 0
	return string.format("%s - %s %s vol:%d%% %s", artist, title, icon, vol, progress(pos, dur, 20))
end

function statusline.detailed(s)
	if not s or not s.current_track then
		return "GTM - not playing"
	end
	local t = s.current_track
	local artist = t.artist or "Unknown"
	local title = t.title or "Unknown"
	local album = t.album or ""
	local icon = status_icon(s)
	local vol = s.volume or 0
	local pos = fmt_time(ipc.estimated_pos())
	local dur = fmt_time(t.duration or 0)

	local parts = { icon }
	table.insert(parts, string.format("%s / %s", artist, title))
	if album ~= "" then
		table.insert(parts, string.format("(%s)", album))
	end
	table.insert(parts, string.format("[%s/%s]", pos, dur))
	table.insert(parts, string.format("vol:%d%%", vol))
	if s["repeat"] and s["repeat"] ~= "Off" then
		table.insert(parts, "[R]")
	end
	if s.shuffle then
		table.insert(parts, "[S]")
	end
	return table.concat(parts, " ")
end

function statusline.render(_opts)
	local s = ipc.last_status
	if _opts.statusline_format == "detailed" then
		return statusline.detailed(s)
	else
		return statusline.compact(s)
	end
end

function statusline.start(_opts)
	statusline.stop()
	statusline._timer = uv.new_timer()
	statusline._timer:start(0, _opts.statusline_interval or 1000, function()
		ipc.send_cmd("get_status")
	end)
end

function statusline.stop()
	if statusline._timer then
		statusline._timer:stop()
		statusline._timer:close()
		statusline._timer = nil
	end
end

function statusline.lualine_component()
	return {
		function()
			return statusline.render(I.opts)
		end,
		cond = function()
			return ipc._connected
		end,
	}
end

-- ============================================================================
-- Library UI: track list buffer with motions
-- ============================================================================

local library = {
	buf_id = nil,
	win_id = nil,
	tracks = {},
	playlists = {},
}

local function library_fmt_track(track, idx)
	local artist = track.artist or "Unknown"
	local title = track.title or "Unknown"
	local duration = track.duration and fmt_time(track.duration) or "--:--"
	return string.format(" %3d  %-30s  %-30s  %s", idx, artist, title, duration)
end

local function library_fmt_playlist(pl, idx)
	local count = pl.track_count or 0
	return string.format(" %3d  %-40s  (%d tracks)", idx, pl.name, count)
end

function library.open(opts)
	if library.win_id and vim.api.nvim_win_is_valid(library.win_id) then
		vim.api.nvim_set_current_win(library.win_id)
		return
	end

	library.buf_id = vim.api.nvim_create_buf(false, true)
	vim.bo[library.buf_id].buftype = "nofile"
	vim.bo[library.buf_id].bufhidden = "wipe"
	vim.bo[library.buf_id].filetype = "gtm-library"

	local width = math.min(100, vim.o.columns - 4)
	local height = math.min(30, vim.o.lines - 6)

	library.win_id = vim.api.nvim_open_win(library.buf_id, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = (opts and opts.float and opts.float.border) or "rounded",
		title = " Library ",
		title_pos = "center",
		style = "minimal",
	})

	local km = {
		["j"] = function() library.move_cursor(1) end,
		["<Down>"] = function() library.move_cursor(1) end,
		["k"] = function() library.move_cursor(-1) end,
		["<Up>"] = function() library.move_cursor(-1) end,
		["gg"] = function() library.move_cursor_to(1) end,
		["G"] = function() library.move_cursor_to(#library.tracks) end,
		["<CR>"] = function() library.select() end,
		["q"] = function() library.close() end,
		["<Esc>"] = function() library.close() end,
		["/"] = function() library.filter() end,
		["d"] = function() library.delete_track() end,
		["a"] = function() library.add_to_queue() end,
		["F"] = function() library.toggle_favourite() end,
		["t"] = function() library.show_playlists() end,
	}
	for lhs, rhs in pairs(km) do
		vim.keymap.set("n", lhs, rhs, { buffer = library.buf_id, noremap = true, silent = true, desc = "GTM lib" })
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = library.buf_id,
		once = true,
		callback = function()
			library.win_id = nil
			library.buf_id = nil
		end,
	})

	library.refresh(opts)
end

function library.close()
	if library.win_id and vim.api.nvim_win_is_valid(library.win_id) then
		vim.api.nvim_win_close(library.win_id, true)
	end
	library.win_id = nil
	library.buf_id = nil
end

function library.refresh(opts)
	ipc.library_get_tracks(nil, nil, function(result)
		vim.schedule(function()
			library.tracks = result or {}
			library.render(opts)
		end)
	end)
end

function library.render(opts)
	if not library.buf_id or not vim.api.nvim_buf_is_valid(library.buf_id) then
		return
	end
	local lines = {}
	table.insert(lines, "  #   Artist                           Title                            Duration")
	table.insert(lines, string.rep("─", 100))
	for i, t in ipairs(library.tracks) do
		table.insert(lines, library_fmt_track(t, i))
	end
	if #library.tracks == 0 then
		table.insert(lines, "  (empty — use :Gtm scan <path> to add music)")
	end
	vim.api.nvim_buf_set_lines(library.buf_id, 0, -1, false, lines)
	vim.bo[library.buf_id].modifiable = false
end

function library.move_cursor(delta)
	if not library.win_id or not vim.api.nvim_win_is_valid(library.win_id) then
		return
	end
	local row = vim.api.nvim_win_get_cursor(library.win_id)[1]
	local new = math.max(3, math.min(#library.tracks + 2, row + delta))
	vim.api.nvim_win_set_cursor(library.win_id, { new, 0 })
end

function library.move_cursor_to(line)
	if not library.win_id or not vim.api.nvim_win_is_valid(library.win_id) then
		return
	end
	local row = math.max(3, math.min(#library.tracks + 2, line + 2))
	vim.api.nvim_win_set_cursor(library.win_id, { row, 0 })
end

function library.select()
	local row = vim.api.nvim_win_get_cursor(library.win_id)[1]
	local idx = row - 2
	local track = library.tracks[idx]
	if track and track.path then
		ipc.send_cmd("play", { path = track.path, start_pos = 0.0 })
	end
end

function library.delete_track()
	local row = vim.api.nvim_win_get_cursor(library.win_id)[1]
	local idx = row - 2
	local track = library.tracks[idx]
	if track then
		ipc.library_remove_track(track.id, function()
			vim.schedule(function()
				library.refresh()
			end)
		end)
	end
end

function library.add_to_queue()
	local row = vim.api.nvim_win_get_cursor(library.win_id)[1]
	local idx = row - 2
	local track = library.tracks[idx]
	if track and track.path then
		ipc.queue_add(track.path, nil, function()
			vim.schedule(function()
				vim.notify("[gtm] added to queue: " .. (track.title or "unknown"))
			end)
		end)
	end
end

function library.toggle_favourite()
	local row = vim.api.nvim_win_get_cursor(library.win_id)[1]
	local idx = row - 2
	local track = library.tracks[idx]
	if track then
		if track.favourite then
			ipc.remove_favourite(track.id, function()
				vim.schedule(function() library.refresh() end)
			end)
		else
			ipc.add_favourite(track.id, function()
				vim.schedule(function() library.refresh() end)
			end)
		end
	end
end

function library.filter()
	vim.ui.input({ prompt = "Filter library: " }, function(query)
		if query then
			ipc.library_get_tracks(query, nil, function(result)
				vim.schedule(function()
					library.tracks = result or {}
					library.render()
				end)
			end)
		end
	end)
end

function library.show_playlists()
	ipc.library_get_playlists(function(result)
		vim.schedule(function()
			library.playlists = result.playlists or {}
			local lines = {}
			table.insert(lines, "  #   Name                                             Tracks")
			table.insert(lines, string.rep("─", 60))
			for i, pl in ipairs(library.playlists) do
				table.insert(lines, library_fmt_playlist(pl, i))
			end
			if #library.playlists == 0 then
				table.insert(lines, "  (no playlists)")
			end
			if library.buf_id and vim.api.nvim_buf_is_valid(library.buf_id) then
				vim.bo[library.buf_id].modifiable = true
				vim.api.nvim_buf_set_lines(library.buf_id, 0, -1, false, lines)
				vim.bo[library.buf_id].modifiable = false
				if library.win_id and vim.api.nvim_win_is_valid(library.win_id) then
					vim.api.nvim_win_set_config(library.win_id, { title = " Playlists " })
				end
			end
		end)
	end)
end

-- ============================================================================
-- YouTube UI: search picker
-- ============================================================================

local yt = {
	buf_id = nil,
	win_id = nil,
	results = {},
}

function yt.search(query)
	if not query or query == "" then
		vim.ui.input({ prompt = "YouTube search: " }, function(q)
			if q and q ~= "" then
				yt._do_search(q)
			end
		end)
	else
		yt._do_search(query)
	end
end

function yt._do_search(query)
	vim.notify("[gtm] searching YouTube: " .. query)
	ipc.yt_search(query, nil, function()
		yt._poll_results()
	end)
end

function yt._poll_results()
	ipc.yt_search_poll(function(resp)
		vim.schedule(function()
			if resp and resp.yt_search_results and resp.yt_search_results.results then
				yt.results = resp.yt_search_results.results
				yt._show_picker()
			elseif resp and resp.ok then
				vim.defer_fn(function()
					yt._poll_results()
				end, 1000)
			else
				vim.notify("[gtm] yt search: no results or still loading", vim.log.levels.INFO)
			end
		end)
	end)
end

function yt._show_picker()
	if yt.win_id and vim.api.nvim_win_is_valid(yt.win_id) then
		vim.api.nvim_set_current_win(yt.win_id)
		return
	end

	yt.buf_id = vim.api.nvim_create_buf(false, true)
	vim.bo[yt.buf_id].buftype = "nofile"
	vim.bo[yt.buf_id].bufhidden = "wipe"
	vim.bo[yt.buf_id].filetype = "gtm-yt"

	local width = math.min(100, vim.o.columns - 4)
	local height = math.min(20, vim.o.lines - 6)

	yt.win_id = vim.api.nvim_open_win(yt.buf_id, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		title = " YouTube Search ",
		title_pos = "center",
		style = "minimal",
	})

	local lines = {}
	for i, r in ipairs(yt.results) do
		local dur = r.duration and fmt_time(r.duration) or "--:--"
		table.insert(lines, string.format(" %3d  %-50s  %-15s  %s", i, r.title, r.channel, dur))
	end
	vim.api.nvim_buf_set_lines(yt.buf_id, 0, -1, false, lines)
	vim.bo[yt.buf_id].modifiable = false

	vim.keymap.set("n", "<CR>", function()
		yt._select_and_download()
	end, { buffer = yt.buf_id, noremap = true, silent = true })
	vim.keymap.set("n", "q", function()
		yt._close()
	end, { buffer = yt.buf_id, noremap = true, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		yt._close()
	end, { buffer = yt.buf_id, noremap = true, silent = true })
end

function yt._select_and_download()
	local row = vim.api.nvim_win_get_cursor(yt.win_id)[1]
	local idx = row
	local result = yt.results[idx]
	if not result then
		return
	end
	yt._close()
	yt.download(result.url, result.title)
end

function yt.download(url, title)
	title = title or url
	vim.notify("[gtm] resolving stream: " .. title)
	ipc.yt_resolve_stream(url, function(info)
		vim.schedule(function()
			if not info or not info.url then
				vim.notify("[gtm] failed to resolve stream", vim.log.levels.ERROR)
				return
			end
			local data_dir = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
			local audio_dir = data_dir .. "/gtm/audio"
			vim.fn.mkdir(audio_dir, "p")
			local safe_title = title:gsub("[/\\:*?\"<>|]", "_"):sub(1, 80)
			local output = audio_dir .. "/" .. safe_title .. ".%(ext)s"
			vim.notify("[gtm] downloading: " .. title)
			vim.fn.jobstart({
				"yt-dlp",
				"--extract-audio",
				"--audio-format", "mp3",
				"--embed-thumbnail",
				"--convert-thumbnails", "jpg",
				"--write-thumbnail",
				"-o", output,
				info.url,
			}, {
				on_exit = function(_, code)
					vim.schedule(function()
						if code == 0 then
							vim.notify("[gtm] downloaded: " .. title)
							ipc.library_scan(audio_dir, function()
								vim.notify("[gtm] library updated")
							end)
						else
							vim.notify("[gtm] download failed (exit " .. code .. ")", vim.log.levels.ERROR)
						end
					end)
				end,
			})
		end)
	end)
end

function yt._close()
	if yt.win_id and vim.api.nvim_win_is_valid(yt.win_id) then
		vim.api.nvim_win_close(yt.win_id, true)
	end
	yt.win_id = nil
	yt.buf_id = nil
end

-- ============================================================================
-- Commands: :Gtm user command and keymaps
-- ============================================================================

local commands = {}

function commands.register(_opts)
	vim.api.nvim_create_user_command("Gtm", function(cmd_args)
		local sub = cmd_args.fargs[1]
		local fargs = cmd_args.fargs

		if sub == "float" or sub == "toggle" then
			float.toggle(_opts)
		elseif sub == "play" then
			I.play_pause()
		elseif sub == "next" then
			I.next()
		elseif sub == "prev" then
			I.prev()
		elseif sub == "stop" then
			I.stop()
		elseif sub == "volup" then
			I.volume_up()
		elseif sub == "voldown" then
			I.volume_down()
		elseif sub == "shuffle" then
			ipc.toggle_shuffle()
		elseif sub == "repeat" then
			local mode = fargs[2] or "all"
			ipc.cycle_repeat(mode)
		elseif sub == "mute" then
			ipc.toggle_mute()
		elseif sub == "seek" then
			local secs = tonumber(fargs[2])
			if secs then
				ipc.seek(secs)
			else
				vim.notify("Gtm seek: expected seconds", vim.log.levels.ERROR)
			end
		elseif sub == "status" then
			ipc.get_status(function(s)
				local icon = "⏹"
				if s.status == "playing" then
					icon = "▶"
				elseif s.status == "paused" then
					icon = "⏸"
				end
				if s.current_track then
					local t = s.current_track
					vim.notify(string.format("%s %s - %s (vol:%d%%)", icon, t.artist, t.title, s.volume or 0))
				else
					vim.notify("GTM: nothing playing")
				end
			end)
		elseif sub == "disconnect" then
			ipc.disconnect()
			vim.notify("[gtm] disconnected")

		-- Library
		elseif sub == "library" or sub == "lib" then
			library.open(_opts)
		elseif sub == "playlists" then
			library.open(_opts)
			vim.defer_fn(function()
				library.show_playlists()
			end, 100)
		elseif sub == "scan" then
			local path = fargs[2]
			if not path then
				vim.notify("Gtm scan: expected path", vim.log.levels.ERROR)
				return
			end
			ipc.library_scan(path, function(result)
				vim.schedule(function()
					vim.notify(string.format("[gtm] scanned: %d new tracks", #(result or {})))
				end)
			end)

		-- Equalizer
		elseif sub == "eq" then
			local arg = fargs[2]
			if arg == "on" then
				ipc.set_eq_enabled(true, function()
					vim.schedule(function() vim.notify("[gtm] EQ enabled") end)
				end)
			elseif arg == "off" then
				ipc.set_eq_enabled(false, function()
					vim.schedule(function() vim.notify("[gtm] EQ disabled") end)
				end)
			elseif arg then
				ipc.set_eq_preset(arg, function(resp)
					vim.schedule(function()
						if resp and resp.ok then
							vim.notify("[gtm] EQ preset: " .. arg)
						else
							vim.notify("[gtm] invalid EQ preset: " .. arg, vim.log.levels.ERROR)
						end
					end)
				end)
			else
				vim.notify("Gtm eq: on|off|preset", vim.log.levels.ERROR)
			end

		-- YouTube
		elseif sub == "yt" then
			local yt_sub = fargs[2]
			if yt_sub == "download" then
				local url_or_query = fargs[3]
				if not url_or_query then
					vim.ui.input({ prompt = "YouTube URL or search: " }, function(input)
						if input and input ~= "" then
							yt.download(input)
						end
					end)
				else
					yt.download(url_or_query)
				end
			elseif yt_sub then
				yt.search(yt_sub)
			else
				yt.search()
			end

		else
			vim.notify("Gtm: unknown subcommand '" .. tostring(sub) .. "'", vim.log.levels.ERROR)
		end
	end, {
		nargs = "+",
		complete = function(arg_lead, cmdline, cursor_pos)
			local subs = {
				"float", "toggle", "play", "next", "prev", "stop",
				"volup", "voldown", "status", "disconnect",
				"shuffle", "repeat", "mute", "seek",
				"library", "lib", "playlists", "scan",
				"eq",
				"yt",
			}
			local parts = vim.split(cmdline, "%s+")
			if #parts <= 2 then
				return vim.tbl_filter(function(s)
					return s:find(arg_lead, 1, true) == 1
				end, subs)
			end
			if parts[2] == "eq" then
				return vim.tbl_filter(function(s)
					return s:find(arg_lead, 1, true) == 1
				end, { "on", "off", "flat", "pop", "rock", "jazz", "classical", "bass", "vocal", "electronic", "hip_hop", "latin", "acoustic", "podcast", "dance", "headphones", "speaker" })
			end
			if parts[2] == "repeat" then
				return vim.tbl_filter(function(s)
					return s:find(arg_lead, 1, true) == 1
				end, { "off", "one", "all" })
			end
			if parts[2] == "yt" then
				return vim.tbl_filter(function(s)
					return s:find(arg_lead, 1, true) == 1
				end, { "download" })
			end
			return {}
		end,
	})

	local km = _opts.keymaps or {}
	local maps = {
		{ km.play_pause, I.play_pause, "play/pause" },
		{ km.next, I.next, "next track" },
		{ km.prev, I.prev, "previous track" },
		{ km.volume_up, I.volume_up, "volume up" },
		{ km.volume_down, I.volume_down, "volume down" },
		{ km.stop, I.stop, "stop" },
	}
	for _, m in ipairs(maps) do
		if m[1] then
			vim.keymap.set("n", m[1], m[2], { desc = "GTM: " .. m[3] })
		end
	end
	if km.float then
		vim.keymap.set("n", km.float, function()
			float.toggle(_opts)
		end, { desc = "GTM: toggle float" })
	end
end

-- ============================================================================
-- Public API
-- ============================================================================

function I.play_pause()
	ipc.send_cmd("play_pause")
end

function I.next()
	ipc.send_cmd("next")
end

function I.prev()
	ipc.send_cmd("prev")
end

function I.stop()
	ipc.send_cmd("stop")
end

function I.volume_up()
	if ipc.last_status then
		local vol = math.min(100, (ipc.last_status.volume or 80) + 5)
		ipc.send_cmd("set_volume", { volume = vol })
	end
end

function I.volume_down()
	if ipc.last_status then
		local vol = math.max(0, (ipc.last_status.volume or 80) - 5)
		ipc.send_cmd("set_volume", { volume = vol })
	end
end

function I.toggle()
	float.toggle()
end

function I.library()
	library.open(I.opts)
end

function I.playlists()
	library.open(I.opts)
	vim.defer_fn(function()
		library.show_playlists()
	end, 100)
end

function I.yt_search(query)
	yt.search(query)
end

function I.yt_download(url_or_query)
	yt.download(url_or_query)
end

function I.set_eq_preset(preset)
	ipc.set_eq_preset(preset)
end

function I.set_eq_enabled(enabled)
	ipc.set_eq_enabled(enabled)
end

function I.lualine_component()
	return statusline.lualine_component()
end

function I.statusline()
	return statusline.render(I.opts)
end

function I.setup(_opts)
	I.opts = vim.tbl_deep_extend("force", vim.deepcopy(default_opts), _opts or {})
	ipc.connect(I.opts.socket_path)
	commands.register(I.opts)
	statusline.start(I.opts)
end

I._ipc = ipc
I._float = float
I._statusline = statusline
I._library = library
I._yt = yt
I._coverart = coverart

return I

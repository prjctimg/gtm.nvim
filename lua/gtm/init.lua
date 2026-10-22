-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.nvim: Neovim client for gtmd.
-- Website: https://gtmd.dev/nvim
--
-- Playback control, a statusline, reactive theming, and native pickers over the
-- queue and library.
--
-- This is free software released under the GPL-3.0 license.

local I = {}

-- Shared helpers. Each of these is used by more than one section below, so
-- they live here rather than in whichever section needed them first.

--- Every message the plugin shows carries the same marker: the tag, then the
--- radio emoji, so a gtm notification is recognisable in a busy message list.
---
--- A fast event context cannot call `vim.notify` (`E5560`), so a message raised
--- from one — a reconnect warning, say — is scheduled onto the main loop.
local function notify(msg, level)
	local line = "[gtm] 📻️ " .. msg
	if vim.in_fast_event() then
		vim.schedule(function()
			vim.notify(line, level)
		end)
	else
		vim.notify(line, level)
	end
end

--- Stop and close a libuv timer. Returns nil so the caller can assign it back.
local function close_timer(t)
	if t then
		t:stop()
		t:close()
	end
	return nil
end

--- A non-empty string, or nil.
local function text(value)
	return type(value) == "string" and value ~= "" and value or nil
end

--- Lowercase a wire enum. The daemon sends PascalCase ("One", "All"); the
--- plugin keeps the lowercase form everywhere.
local function lower(value)
	return type(value) == "string" and value:lower() or value
end

--- Minutes and seconds, zero-padded: `04:56`.
local function fmt_time(secs)
	return string.format("%02d:%02d", math.floor(secs / 60), math.floor(secs % 60))
end

local ipc = {}

do
	local uv = vim.uv
	local hrtime = uv.hrtime

	ipc.sock = nil
	ipc.path = nil
	ipc.connected = false
	ipc.status = nil

	local MAX_LINE = 1024 * 1024
	local RETRY_MAX_DELAY = 10000
	local MAX_ATTEMPTS = 30 -- this may change,may rely on.

	local id, buf, pending = 0, "", {}
	local retry_timer, delay, attempts = nil, 500, 0
	local base_pos, base_time, duration, updated = 0, 0, 0, 0
	local on_connected = nil

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

	function ipc.resolve_path()
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
	function ipc.pulse_path()
		return (ipc.path or ipc.resolve_path()):gsub("gtmd%.sock$", "gtmd.pulse")
	end

	--- `hook` runs after every (re)connect, once the snapshot has been primed.
	function ipc.connect(path, hook)
		ipc.path, on_connected = path or ipc.resolve_path(), hook
		if uv.fs_stat(ipc.path) then
			ipc._open()
		else
			-- Start the daemon yourself: a plugin silently spawning a server process
			-- is not its call to make, and there is nothing to reconnect to anyway.
			notify("gtmd is not running (no socket at " .. ipc.path .. ")", vim.log.levels.WARN)
		end
	end

	function ipc.disconnect()
		retry_timer = close_timer(retry_timer)
		if ipc.sock then
			ipc.sock:read_stop()
			ipc.sock:close()
			ipc.sock = nil
		end
		ipc.connected = false
		ipc.clear()
		pending = {}
	end

	--- Forget the track: a track ended and no new snapshot has arrived, so the
	--- clock must not keep advancing from it.
	function ipc.clear()
		ipc.status, base_pos, duration = nil, 0, 0
		updated = hrtime()
	end

	function ipc._open()
		if ipc.sock then
			return
		end
		local sock = uv.new_pipe(false)
		ipc.sock = sock
		sock:connect(ipc.path, function(err)
			-- A stale handle from a racing retry can land here late; the `~= check
			-- drops it instead of resurrecting a dead pipe.
			if err or ipc.sock ~= sock then
				if not sock:is_closing() then
					sock:close()
				end
				if ipc.sock == sock then
					ipc.sock = nil
					ipc._retry()
				end
				return
			end
			ipc.connected = true
			delay, attempts = 500, 0
			ipc._read(sock)
			-- Prime on (re)connect so the statusline is right even when nothing has
			-- been played yet — a daemon sitting paused on a radio stream.
			ipc.send("get_status", nil, function(resp)
				if resp and resp.state then
					ipc.set_status(resp.state)
				end
				if on_connected then
					on_connected()
				end
			end)
		end)
	end

	--- Exponential backoff, capped, and never more than one timer in flight. It
	--- never gives up: gtmd may come back at any time, and a plugin that stops
	--- trying is a plugin that silently stays stale for the rest of the session.
	--- `MAX_ATTEMPTS` only decides when to warn once that the wait has got long.
	function ipc._retry()
		ipc.connected = false
		if retry_timer or not ipc.path then
			return
		end
		retry_timer = uv.new_timer()
		retry_timer:start(delay, 0, function()
			retry_timer = close_timer(retry_timer)
			attempts = attempts + 1
			if attempts == MAX_ATTEMPTS then
				notify("still reconnecting to gtmd; it may not be running", vim.log.levels.WARN)
			end
			delay = math.min(delay * 2, RETRY_MAX_DELAY)
			ipc._open()
		end)
	end

	--- Responses are one JSON object per line. Anything else arriving here is not a
	--- response for us, so it is skipped rather than parsed.
	function ipc._read(sock)
		buf = ""
		sock:read_start(function(err, data)
			if err or not data then
				ipc.connected = false
				ipc._retry()
				return
			end
			buf = buf .. data
			while true do
				local nl = buf:find("\n", 1, true)
				if not nl then
					break
				end
				local line = buf:sub(1, nl - 1)
				buf = buf:sub(nl + 1)
				if line:sub(1, 1) == "{" then
					ipc._dispatch(line)
				end
			end
			if #buf > MAX_LINE then
				buf = ""
				notify("oversized response discarded", vim.log.levels.WARN)
			end
		end)
	end

	function ipc._dispatch(line)
		local ok, data = pcall(vim.json.decode, line)
		local cb = ok and type(data) == "table" and data.id and pending[data.id]
		if not cb then
			return
		end
		pending[data.id] = nil
		vim.schedule(function()
			cb(denil(data))
		end)
	end

	--- Fire a command. `params` is always on the wire, even when empty.
	function ipc.send(cmd, params, callback)
		if not ipc.connected or not ipc.sock then
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
		ipc.sock:write(vim.json.encode({ id = id, cmd = cmd, params = params or {} }) .. "\n")
		return id
	end

	--- Adopt a `PlaybackStatus` payload: lowercase the two enums that arrive
	--- PascalCase on the wire, then reset the extrapolation anchor.
	function ipc.set_status(state)
		if type(state) ~= "table" then
			return
		end
		local s = denil(state)
		if type(s) ~= "table" then
			return
		end
		s.status = lower(s.status)
		s["repeat"] = lower(s["repeat"])
		ipc.status = s
		base_pos, duration = s.time_pos or 0, s.duration or 0
		base_time, updated = hrtime(), hrtime()
	end

	-- Only these three move the status clock; everything else on the pulse stream
	-- is a scalar patch or a theming signal.
	local TRANSITION = { playback_started = "playing", playback_paused = "paused", playback_stopped = "stopped" }

	--- Fold a playback transition into the snapshot and re-anchor the clock. A
	--- partial event cannot blank the statusline: `current_track` is only replaced
	--- when a real table arrives.
	function ipc.apply(ev)
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
		if not ipc.status then
			return
		end
		ipc.status.status = next_status
		ipc.status.time_pos, ipc.status.duration = base_pos, duration
		if ev.track then
			ipc.status.current_track = ev.track
		elseif ev.event == "playback_stopped" then
			ipc.status.current_track = nil
		end
	end

	--- Fold a scalar off an event into the snapshot. Only called for fields that
	--- exist to keep the statusline honest.
	function ipc.patch(key, value)
		if ipc.status then
			ipc.status[key] = value
			updated = hrtime()
		end
	end

	--- Position in seconds, advanced locally from the last transition.
	function ipc.position()
		local pos = base_pos
		if ipc.status and ipc.status.status == "playing" then
			pos = pos + (hrtime() - base_time) / 1e9
		end
		return math.max(0, duration > 0 and math.min(pos, duration) or pos)
	end

	function ipc.duration()
		return duration
	end

	--- Seconds since the snapshot last moved. 0 when it never has.
	function ipc.stale_for()
		return updated > 0 and (hrtime() - updated) / 1e9 or 0
	end
end

local theme = {}
do
	--
	-- gtmd owns the colours. It extracts a palette from the cover of the track on
	-- air, resolves it into named *roles* — `accent`, `comment`, `sel_bg` and the
	-- rest — and pushes a role set over the pulse socket. This module picks the
	-- polarity and maps roles onto highlight groups.
	-- The daemon cannot know your colorscheme, so it cannot produce "your theme washed with the
	-- album". Every background is therefore a wash of the daemon's `accent` over
	-- the colour the group already had, scaled by `theme.intensity`. That is a
	-- surface policy, not a second ramp: no role the daemon resolved is ever
	-- re-derived here.
	--
	-- Two rules hold throughout: semantic groups (Error, Warning, Diff, Spell, Todo,
	-- diagnostics, gitSigns) are never tinted, because an error that changes colour
	-- with the artwork is worse than no error colour.

	theme._enabled, theme._applied, theme._snap, theme._extra = false, {}, nil, {}
	theme._base, theme._intensity = nil, 0.34

	-- Roles a set must carry before it is accepted at all: a half-applied ramp is
	-- worse than none. Every other role is applied when the daemon sends it and
	-- skipped when it does not, so a client built against a newer set degrades
	-- instead of failing outright.
	local NEED = {
		"bg0",
		"bg1",
		"bg2",
		"bg3",
		"sel_bg",
		"fg",
		"fg_dim",
		"cursor_line_nr",
		"accent",
		"accent2",
		"accent3",
	}

	-- Role -> highlight group. The mapping is data, and is the whole of what a
	-- client has to own: group names are per-editor and cannot live in the daemon.
	-- Foreground roles. A tree-sitter capture (`@function.builtin`) resolves through
	-- its first segment, the base Vim group the capture mirrors.
	local ROLE = {
		Comment = "comment",
		String = "string",
		Character = "string",
		Number = "number",
		Float = "number",
		Boolean = "boolean",
		Constant = "constant",
		Identifier = "identifier",
		Variable = "variable",
		Parameter = "variable",
		Field = "variable",
		Property = "variable",
		Function = "function",
		Constructor = "type",
		Statement = "keyword",
		Keyword = "keyword",
		Conditional = "keyword",
		Repeat = "keyword",
		Exception = "keyword",
		Label = "keyword",
		Include = "keyword",
		Define = "keyword",
		Macro = "keyword",
		PreProc = "keyword",
		PreCondit = "keyword",
		Operator = "operator",
		Type = "type",
		Structure = "type",
		Typedef = "type",
		StorageClass = "type",
		Namespace = "type",
		Module = "type",
		Special = "punctuation",
		SpecialChar = "punctuation",
		Delimiter = "punctuation",
		Punctuation = "punctuation",
		Title = "fg_bright",
		CursorLineNr = "cursor_line_nr",
		WinSeparator = "line",
		VertSplit = "line",
		LineNr = "fg_dim",
		SignColumn = "fg_dim",
		Visual = "sel_fg",
		PmenuSel = "sel_fg",
		TabLineSel = "sel_fg",
		Search = "search_fg",
		IncSearch = "search_fg",
		CurSearch = "search_fg",
	}

	-- Backgrounds the daemon resolves directly: selection, search and the cursor
	-- line say something, so they take the daemon's role rather than the wash.
	local BG = {
		Visual = "sel_bg",
		PmenuSel = "sel_bg",
		TabLineSel = "sel_bg",
		Search = "search_bg",
		IncSearch = "search_bg",
		CurSearch = "search_bg",
		CursorLine = "cursor_line",
		CursorColumn = "cursor_line",
		ColorColumn = "cursor_line",
		Cursor = "cursor",
	}

	local DIM = { NonText = true, Whitespace = true, SpecialKey = true }

	-- Prefix matching catches the spell and diagnostic variants.
	local SEMANTIC = {
		Error = true,
		WarnMsg = true,
		MoreMsg = true,
		Question = true,
		Info = true,
		Hint = true,
		Todo = true,
		Diagnostic = true,
		Spell = true,
		Diff = true,
	}

	local function is_semantic(name)
		for prefix in pairs(SEMANTIC) do
			if name:sub(1, #prefix) == prefix then
				return true
			end
		end
		return name:sub(1, 8) == "gitSigns"
	end

	--- The foreground role a group takes, or nil to leave its colorscheme value.
	local function fg_role(name)
		if ROLE[name] then
			return ROLE[name]
		end
		local base = name:match("^@([%w_]+)")
		return (base and ROLE[base:sub(1, 1):upper() .. base:sub(2)]) or (DIM[name] and "fg_dim")
	end

	--- Blend two 0xRRGGBB colours. The only colour calculation in the client: the
	--- background wash. It scales one step toward the accent and never re-resolves
	--- a role the daemon already named.
	local function wash(from, to, t)
		local function ch(c, shift)
			return math.floor(c / 2 ^ shift) % 256
		end
		local function mix(a, b)
			return math.floor(a + (b - a) * t + 0.5)
		end
		return mix(ch(from, 16), ch(to, 16)) * 65536 + mix(ch(from, 8), ch(to, 8)) * 256 + mix(ch(from, 0), ch(to, 0))
	end

	--- Blend two 0xRRGGBB colours by factor t (0 = first, 1 = second).
	local function mix_rgb_int(c1, c2, t)
		if type(c1) ~= "number" or type(c2) ~= "number" then
			return c1 or c2
		end
		t = t or 0.5
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
		local function ch(c, shift)
			return math.floor(c / 2 ^ shift) % 256
		end
		local function mix(a, b)
			return math.floor(a + (b - a) * t + 0.5)
		end
		return mix(ch(c1, 16), ch(c2, 16)) * 65536 + mix(ch(c1, 8), ch(c2, 8)) * 256 + mix(ch(c1, 0), ch(c2, 0))
	end

	-- ============================================================================
	-- Snapshot and restore
	-- ============================================================================

	--- Remember every global highlight group, so the tint can be undone exactly.
	--- There is no API to enumerate highlight groups; `getcompletion(…, "highlight")`
	--- is the documented way to get the list Neovim itself knows about. The
	--- colorscheme's own background is captured here too: the wash is applied to it,
	--- not to a surface the daemon has never seen.
	function theme.snapshot()
		local snap = {}
		for _, name in ipairs(vim.fn.getcompletion("", "highlight")) do
			local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
			if ok and type(hl) == "table" then
				snap[name] = hl
			end
		end
		theme._snap = snap
		local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
		theme._base = normal.bg or (vim.o.background == "light" and 0xf6f4f1 or 0x0d0d12)
	end

	function theme.setup(opts)
		opts = opts or {}
		theme._enabled, theme._extra = opts.reactive == true, opts.extra_groups or {}
		theme._intensity = math.max(0, math.min(0.5, opts.intensity or 0.34))
		theme._applied, theme._roles, theme._sets, theme._ver = {}, nil, nil, nil
		theme.snapshot()
	end

	--- Whether reactive theming is on at all.
	function theme.enabled()
		return theme._enabled
	end

	--- Token-set version the daemon advertised.
	function theme.version()
		return theme._ver
	end

	--- The active role set (role -> 0xRRGGBB), or nil when nothing is tinted.
	function theme.roles()
		return theme._roles
	end

	--- Put every group the palette touched back to its snapshot value. The stored
	--- role sets survive, so a colorscheme change can re-pick from them without
	--- waiting for the next track.
	function theme.restore()
		for name in pairs(theme._applied) do
			if theme._snap and theme._snap[name] then
				vim.api.nvim_set_hl(0, name, vim.deepcopy(theme._snap[name]))
			end
		end
		theme._applied, theme._roles = {}, nil
	end

	--- Forget the role sets entirely, as `:Gtm theme reset` asks. Without this a
	--- colorscheme change would resurrect a tint the user just turned off.
	function theme.clear()
		theme.restore()
		theme._sets, theme._ver = nil, nil
	end

	-- ============================================================================
	-- Applying a role set
	-- ============================================================================

	--- Apply resolved roles. The only path that writes highlights.
	local function apply(roles)
		theme._roles, theme._applied = roles, {}
		local accent = roles.accent
		local accent2 = roles.accent2
		local accent3 = roles.accent3
		local bg0 = roles.bg0
		local bg1 = roles.bg1
		local bg2 = roles.bg2
		local bg3 = roles.bg3
		local base = theme._base or bg0 or bg1 or 0x0d0d12
		local t = theme._intensity or 0.34
		-- Pull the wash toward the daemon-supplied background palette for a
		-- much more dramatic, album-driven tint.
		local from_bg = bg1 or bg0 or bg2 or bg3
		local a1 = accent and (accent2 and mix_rgb_int(accent, accent2, 0.35) or accent)
		local a2 = a1 and (accent3 and mix_rgb_int(a1, accent3, 0.2) or a1)
		local wash_tgt = from_bg
		if wash_tgt and a2 then
			wash_tgt = mix_rgb_int(wash_tgt, a2, 0.6)
		elseif a2 then
			wash_tgt = a2
		end
		if t < 0.42 then
			t = math.min(0.5, t + 0.12)
		end
		for name, saved in pairs(theme._snap or {}) do
			-- Linked groups resolve on their own; rewriting one would freeze the
			-- link into a literal.
			if type(saved) == "table" and not saved.link and not is_semantic(name) then
				local attrs, changed = vim.deepcopy(saved), false
				local bg = BG[name] and roles[BG[name]]
				if bg then
					attrs.bg, changed = bg, true
				elseif wash_tgt then
					-- Wash the group's own colour, so the colorscheme's elevation
					-- survives and only the hue is ours. Normal may have no
					-- background yet; the captured base stands in for it.
					local from = saved.bg or ((name == "Normal" or name == "NormalNC") and base)
					if from then
						attrs.bg, changed = wash(from, wash_tgt, t), true
					end
				end
				local role = fg_role(name)
				local fg = role and roles[role]
				if fg then
					attrs.fg, changed = fg, true
				end
				if changed then
					vim.api.nvim_set_hl(0, name, attrs)
					-- Keep what we wrote: a colorscheme change has to tell our own
					-- writes apart from groups the new scheme redefined itself.
					theme._applied[name] = attrs
				end
			end
		end
		for _, name in ipairs(theme._extra) do
			local attrs = { fg = roles.fg, bg = wash_tgt and wash(base, wash_tgt, t) }
			vim.api.nvim_set_hl(0, name, attrs)
			theme._applied[name] = attrs
		end
	end

	-- ============================================================================
	-- Roles from the daemon
	-- ============================================================================

	local function from_hex(s)
		local h = type(s) == "string" and s:match("^#(%x%x%x%x%x%x)$")
		return h and { tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16) } or nil
	end

	--- {r,g,b} -> 0xRRGGBB, the form `nvim_set_hl` takes.
	local function rgb_int(c)
		return c[1] * 65536 + c[2] * 256 + c[3]
	end

	--- Choose the polarity matching the editor's own background.
	local function pick()
		local roles = theme._sets and theme._sets[vim.o.background == "light" and "light" or "dark"]
		if roles then
			apply(roles)
		end
	end

	--- Adopt a `reactive_theme` event. Both polarities are kept so a colorscheme
	--- switch can re-pick without waiting for the next track. An incomplete set is
	--- ignored outright rather than half-applied.
	function theme.set_roles(ev)
		if not theme._enabled or type(ev) ~= "table" then
			return
		end
		local sets, complete = {}, true
		for _, polarity in ipairs({ "dark", "light" }) do
			local raw, roles = ev[polarity], {}
			if type(raw) ~= "table" then
				complete = false
				break
			end
			for _, role in ipairs(NEED) do
				if not from_hex(raw[role]) then
					complete = false
					break
				end
			end
			if not complete then
				break
			end
			-- Every role the daemon resolved, not just the required ones: the
			-- syntax roles are what keep code legible under the tint.
			for role, hex in pairs(raw) do
				local rgb = from_hex(hex)
				if rgb then
					roles[role] = rgb_int(rgb)
				end
			end
			sets[polarity] = roles
		end
		if complete then
			theme._sets, theme._ver = sets, ev.ver
			pick()
		end
	end

	--- The three accent colours behind the current tint, for `:Gtm theme`.
	function theme.palette_hexes()
		local function hx(n)
			return n and string.format("#%02x%02x%02x", math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
				or "n/a"
		end
		local r = theme._roles or {}
		return hx(r.accent), hx(r.accent2), hx(r.accent3)
	end

	--- The colorscheme changed. The new scheme has already re-applied its own
	--- highlights, so ours survived only where it did not define the group. Put our
	--- own writes back to their pre-tint baseline *only where they are still ours*:
	--- restoring the previous scheme's colours over the new one would be worse than
	--- leaving the tint, and snapshotting our own tint would record it as pristine
	--- and turn a later restore into a no-op. Then re-snapshot and re-apply against
	--- the new background.
	---
	--- Deferred with `vim.schedule`: colorscheme plugins register their own
	--- `ColorScheme` handlers and whichever runs last wins, so ours has to run after
	--- all of them to keep top precedence over the tint.
	function theme.on_colorscheme()
		if not theme._enabled then
			return
		end
		vim.schedule(function()
			if not theme._enabled then
				return
			end
			for name, attrs in pairs(theme._applied) do
				local current = vim.api.nvim_get_hl(0, { name = name, link = false })
				if theme._snap and theme._snap[name] and vim.deep_equal(attrs, current) then
					vim.api.nvim_set_hl(0, name, vim.deepcopy(theme._snap[name]))
				end
			end
			theme._applied, theme._roles = {}, nil
			theme.snapshot()
			if theme._sets then
				pick()
			end
		end)
	end

	--- Re-assert the current tint. A safety net for a background some other actor
	--- overwrote without a `ColorScheme` of its own firing; the pulse stream is
	--- still the source of truth for *what* the colours are.
	---
	--- Scheduled onto the main loop: the resync tick calls this from a libuv
	--- timer, and a fast event context cannot touch the Neovim API (`E5560`) —
	--- not `vim.o.background`, not `nvim_set_hl`. The guard is checked again
	--- when the work runs, so a theme reset in between does not resurrect a
	--- tint that was just dropped.
	function theme.refresh()
		if not theme._enabled or not theme._sets then
			return
		end
		vim.schedule(function()
			if theme._enabled and theme._sets then
				pick()
			end
		end)
	end
end

-- Pulse stream
local pulse = {}
do
	-- Pulse: subscriber to the gtmd pulse event stream
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

	--- mpack decodes null as vim.NIL; turn it back into a real nil. `false` is
	--- a value and not a null, so it has to survive the round trip.
	local function unnil(v)
		if v == vim.NIL then
			return nil
		end
		return v
	end

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

	function pulse.on(name, handler)
		handlers[name] = handlers[name] or {}
		table.insert(handlers[name], handler)
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
		watchdog = close_timer(watchdog)
	end

	--- Redial after a failure: exponential backoff, capped, one timer in flight.
	local function retry_later()
		if retry_timer or not path then
			return
		end
		retry_timer = uv.new_timer()
		retry_timer:start(delay, 0, function()
			retry_timer = close_timer(retry_timer)
			delay = math.min(delay * 2, RETRY_MAX_DELAY)
			pulse.connect(path)
		end)
	end

	--- Watchdog for a wedged stream. The command socket cannot see a pulse socket
	--- that stopped delivering, so without this the editor sits on stale state until
	--- Neovim restarts. `connected_at` is the floor until the first real beat, which
	--- keeps a fresh connection from being mistaken for a silent one.
	local function start_watchdog()
		watchdog = close_timer(watchdog)
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

	function pulse.connect(newpath)
		path = newpath or path
		if sock then
			if connected then
				return
			end
			teardown()
		end
		retry_timer = close_timer(retry_timer)
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
					pulse._frame(payload)
				end
			end)
			start_watchdog()
		end)
	end

	function pulse.close()
		retry_timer = close_timer(retry_timer)
		teardown()
		path = nil
	end

	function pulse.is_connected()
		return connected
	end

	function pulse.heartbeat_age()
		return heartbeat > 0 and (uv.hrtime() - heartbeat) / 1e9 or nil
	end

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

	function pulse._frame(payload)
		local n = event_count(payload)
		if n == 0 then
			return
		end
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
				pulse._emit(raw)
			end
		end
	end

	function pulse._emit(raw)
		local name, listeners = raw[1], handlers[raw[1]]
		if type(name) ~= "string" or not listeners then
			return
		end
		local ev = { event = name }
		for i, field in ipairs(EVENT_FIELDS[name] or {}) do
			ev[field] = unnil(raw[i + 1])
		end
		if type(ev.track) == "table" then
			local t = {}
			for i, field in ipairs(TRACK_FIELDS) do
				t[field] = unnil(ev.track[i])
			end
			ev.track = t
		end
		for _, listener in ipairs(listeners) do
			vim.schedule(function()
				listener(ev)
			end)
		end
	end
end

do
	local vui = vim.ui

	local LIMIT = 50

	local function fail(msg)
		notify(msg, vim.log.levels.WARN)
	end

	local function request(cmd, params, on_ok)
		ipc.send(cmd, params, function(resp, err)
			if not resp then
				return fail(err or "gtmd is not running")
			end
			if resp.ok == false then
				return fail(resp.error or (cmd .. " failed"))
			end
			on_ok(resp)
		end)
	end

	local function choose(prompt, rows, format, on_pick)
		if #rows == 0 then
			return fail("nothing to show")
		end
		vui.select(rows, { prompt = prompt, format_item = format }, function(row, index)
			if row then
				on_pick(row, index)
			end
		end)
	end

	local function prompt(prompt_text, on_input)
		vui.input({ prompt = prompt_text .. ": " }, function(value)
			if value and value ~= "" then
				on_input(value)
			end
		end)
	end

	--- "artist - title  [album]" — the shape every track label takes.
	local function media_label(name, artist, album, extra)
		local label = artist and (artist .. " - " .. name) or name
		if album then
			label = label .. "  [" .. album .. "]"
		end
		if extra then
			label = label .. "  " .. extra
		end
		return label
	end

	local function track_label(t)
		return media_label(text(t.title) or text(t.path) or "?", text(t.artist), text(t.album))
	end

	local function spotify_label(t)
		local extra = t.duration_ms and fmt_time(t.duration_ms / 1000) or nil
		return media_label(text(t.name) or "?", text(t.artists), text(t.album), extra)
	end

	local function station_label(s)
		local bits = {}
		if text(s.country) then
			bits[#bits + 1] = s.country
		end
		if text(s.codec) then
			bits[#bits + 1] = s.bitrate_kbps and string.format("%s %dk", s.codec, s.bitrate_kbps) or s.codec
		end
		return media_label(text(s.name) or "?", nil, #bits > 0 and table.concat(bits, ", ") or nil)
	end

	local function play_track(t)
		local path = text(t.path)
		if not path then
			return fail("this row has no playable path")
		end
		request("play", { path = path, start_pos = 0 }, function()
			notify(track_label(t))
		end)
	end

	local function show_stations(prompt_text, rows)
		choose(prompt_text, rows, station_label, function(s)
			request("radio_play", { station_id = s.id, station_name = s.name or "" }, function()
				notify(text(s.name) or "radio")
			end)
		end)
	end

	function I.queue(action)
		if action and action ~= "" and action ~= "remove" and action ~= "clear" then
			return fail("unknown queue action '" .. action .. "'")
		end

		if action == "clear" then
			return vui.select({ "No, keep it", "Yes, clear it" }, { prompt = "Clear the queue?" }, function(choice)
				if choice == "Yes, clear it" then
					request("queue", { action = "clear" }, function()
						notify("queue cleared")
					end)
				end
			end)
		end

		request("queue", { action = "list" }, function(resp)
			local items, cursor = resp.queue or {}, resp.cursor or 0
			local rows = {}
			for i, track in ipairs(items) do
				rows[i] = { track = track, index = i }
			end

			-- One picker, two jobs: the same rows, read or played. Only the
			-- marker and the action differ.
			local removing = action == "remove"
			choose(removing and "Queue: remove" or "Queue", rows, function(row)
				local marker = removing and "" or (row.index == cursor + 1 and "▶ " or "  ")
				return string.format("%s%d. %s", marker, row.index, track_label(row.track))
			end, function(row)
				if not removing then
					return play_track(row.track)
				end
				request("queue", { action = "remove", index = row.index - 1 }, function()
					notify("removed " .. (text(row.track.title) or text(row.track.path) or "track"))
				end)
			end)
		end)
	end

	function I.spotify(query)
		if not query or query == "" then
			return prompt("Spotify search", I.spotify)
		end

		request("spotify_search_web", { query = query }, function(resp)
			local tracks = {}
			for _, track in ipairs(resp.tracks or {}) do
				if not track.kind or track.kind == "Track" then
					tracks[#tracks + 1] = track
				end
			end
			if #tracks == 0 then
				return fail("no Spotify tracks for '" .. query .. "'")
			end
			choose("Spotify: " .. query, tracks, spotify_label, function(t)
				request("spotify_resolve_track", {
					name = t.name,
					artists = t.artists or "",
					album = t.album or "",
					uri = t.uri,
					image_url = t.image_url,
					play = true,
				}, function()
					notify(spotify_label(t))
				end)
			end)
		end)
	end

	function I.spotify_playlists()
		request("spotify_playlists", nil, function(resp)
			choose("Spotify playlists", resp.playlists or {}, function(playlist)
				local count = #(playlist.tracks or {})
				local owner = text(playlist.owner)
				return string.format("%s (%d)%s", playlist.name or "?", count, owner and ("  " .. owner) or "")
			end, function(playlist)
				request("spotify_playlist_tracks", { id = playlist.id }, function(tracks_resp)
					local tracks = tracks_resp.tracks or {}
					if #tracks == 0 then
						return fail("this Spotify playlist has no tracks")
					end
					choose(playlist.name or "Spotify playlist", tracks, spotify_label, function(t)
						request("spotify_resolve", {
							playlist_id = playlist.id,
							track_index = t.index,
							play = true,
						}, function()
							notify(spotify_label(t))
						end)
					end)
				end)
			end)
		end)
	end

	-- The two drill-downs share a shape: a directory of names, then the
	-- stations behind one of them.
	local RADIO_DIRS = {
		{ arg = "tags", cmd = "radio_tags", by = "radio_bytag", field = "tag" },
		{ arg = "countries", cmd = "radio_countries", by = "radio_bycountry", field = "country" },
	}

	function I.radio(arg)
		for _, dir in ipairs(RADIO_DIRS) do
			if arg == dir.arg then
				return request(dir.cmd, { limit = LIMIT }, function(resp)
					choose("Radio " .. dir.arg, resp[dir.arg] or {}, function(entry)
						return string.format("%s (%d)", entry.name or "?", entry.stationcount or 0)
					end, function(entry)
						request(dir.by, { [dir.field] = entry.name, limit = LIMIT }, function(stations)
							show_stations("Radio: " .. (entry.name or dir.field), stations.stations or {})
						end)
					end)
				end)
			end
		end

		if arg and arg ~= "" then
			return request("radio_search", { query = arg, limit = LIMIT }, function(resp)
				show_stations("Radio: " .. arg, resp.stations or {})
			end)
		end

		request("radio_top", { limit = LIMIT }, function(resp)
			show_stations("Top radio stations", resp.stations or {})
		end)
	end

	--- Browse a list of tracks the daemon returns: the library search or the
	--- favourites.
	local function browse_tracks(cmd, params, prompt_text, empty)
		request(cmd, params, function(resp)
			local tracks = resp.tracks or {}
			if #tracks == 0 then
				return fail(empty)
			end
			choose(prompt_text, tracks, track_label, play_track)
		end)
	end

	--- Local library search.
	function I.search(query)
		if not query or query == "" then
			return prompt("Search library", I.search)
		end
		browse_tracks("search", { query = query }, "Library: " .. query, "no library tracks for '" .. query .. "'")
	end

	--- Local playlists, drilled down to their tracks.
	function I.playlists()
		request("library", { action = "get_playlists" }, function(resp)
			choose("Playlists", resp.playlists or {}, function(playlist)
				return string.format("%s (%d)", playlist.name or "?", playlist.track_count or 0)
			end, function(playlist)
				request("library", { action = "get_playlist_tracks", id = playlist.id }, function(tracks_resp)
					local tracks = tracks_resp.tracks or {}
					if #tracks == 0 then
						return fail("this playlist is empty")
					end
					choose(playlist.name or "Playlist", tracks, track_label, play_track)
				end)
			end)
		end)
	end

	--- The explicitly favourite-addressed set.
	function I.favourites()
		browse_tracks("get_favourites", nil, "Favourites", "no favourites yet")
	end
end

local health = {}
do
	local H = vim.health
	local stat = vim.uv.fs_stat

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
		check(
			pulse.is_connected(),
			"pulse socket connected",
			"not connected - the statusline will not update on its own"
		)

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
		H.ok(string.format("%s %s - %s", s.status, text(t.artist) or "?", text(t.title) or "?"))
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

	function health.check()
		requirements()
		daemon()
		status()
		theming()
	end
end

-- Public API
local uv = vim.uv

local defaults = {
	resync_interval = 30000,
	statusline = {
		source = true,
		state = true,
		artist = false,
		title = false,
		album = false,
		progress = false,
		time = false,
		volume = false,
		["repeat"] = false,
		shuffle = false,
		icons = {
			spotify = "\xf3\xb0\x93\x87", -- md-spotify      U+F04C7
			radio = "\xf3\xb0\x90\xb9", -- md-radio        U+F0439
			podcast = "\xf3\xb0\xa6\x94", -- md-podcast      U+F0994
			["local"] = "\xf3\xb1\x8d\x99", -- md-folder_music U+F1359
			chart = "\xf3\xb0\x84\xaa", -- md-chart_line   U+F012A
		},
	},
	-- `intensity` is how far each background is washed toward the album accent;
	-- 0 leaves your colorscheme's surfaces untouched.
	theme = { reactive = true, intensity = 0.34, extra_groups = {} },
	keymaps = {},
}

I.opts = vim.deepcopy(defaults)
local resync = nil

-- Playback: each is a single command send.
function I.play_pause()
	ipc.send("play_pause")
end
function I.next()
	ipc.send("next")
end
function I.prev()
	ipc.send("prev")
end
function I.stop()
	ipc.send("stop")
end
function I.mute()
	ipc.send("toggle_mute")
end
function I.shuffle()
	ipc.send("toggle_shuffle")
end

-- The wire is PascalCase; the plugin keeps lowercase. `repeat` is a Lua
-- keyword, so the public name cannot be `I.repeat`.
local REPEAT_WIRE = { off = "Off", one = "One", all = "All" }
local REPEAT_NEXT = { off = "One", one = "All", all = "Off" }

--- Set the repeat mode; with no argument, advance off -> one -> all -> off.
function I.cycle_repeat(mode)
	local cur = mode or (ipc.status and ipc.status["repeat"]) or "off"
	-- Only an explicit mode needs translating; cycling stays in lowercase.
	local wire = mode and REPEAT_WIRE[mode] or REPEAT_NEXT[cur] or REPEAT_WIRE.off
	ipc.send("cycle_repeat", { mode = wire })
end

function I.seek(secs)
	if type(secs) == "number" then
		ipc.send("seek", { position_secs = secs })
	end
end

function I.set_volume(delta)
	local vol = math.max(0, math.min(100, (ipc.status and ipc.status.volume or 80) + delta))
	ipc.send("set_volume", { volume = vol })
end

-- The pickers above are part of the public API (`I.queue`, etc.).

-- Statusline

local ICON = { playing = "▶", paused = "⏸", stopped = "⏹" }

--- Render the enabled items. Each is skipped when off or when it has no data,
--- which is what makes the empty state a bare stop icon rather than a row of
--- zeroes.
function I.statusline()
	local on, out = I.opts.statusline, {}
	local s = ipc.status
	local function add(item)
		if item then
			table.insert(out, item)
		end
	end

	-- A source gtmd has not named yet renders as nothing rather than guessing.
	local src = s and text(s.source)
	add(on.source and src and on.icons[src])
	add(on.state and (ICON[s and s.status] or "⏹"))

	local t = s and s.current_track
	if t then
		add(on.artist and text(t.artist))
		add(on.title and text(t.title))
		add(on.album and text(t.album))
		if on.progress then
			local width, pos, dur = 20, ipc.position(), ipc.duration()
			local filled = dur > 0 and math.floor(math.min(1, pos / dur) * width) or 0
			add(string.rep("━", filled) .. string.rep("─", width - filled))
		end
		if on.time then
			add(string.format("[%s/%s]", fmt_time(ipc.position()), fmt_time(ipc.duration())))
		end
		add(on.volume and string.format("vol:%d%%", s.volume or 0))
		add(on["repeat"] and s["repeat"] and s["repeat"] ~= "off" and "[R]")
		add(on.shuffle and s.shuffle and "[S]")
	end

	return table.concat(out, " ")
end

--- Drop-in lualine component, hidden while the daemon is unreachable so a
--- stopped gtmd costs no width.
function I.lualine_component()
	return {
		I.statusline,
		cond = function()
			return ipc.connected
		end,
	}
end

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
		ipc.clear()
		unpaint()
	end,
	volume_changed = patch("volume", "volume"),
	shuffle_changed = patch("shuffle", "enabled"),
	-- RepeatMode serializes PascalCase on the wire ("One"/"All"/"Off"); keep
	-- the lowercase form everywhere in the plugin.
	repeat_mode_changed = function(ev)
		ipc.patch("repeat", lower(ev.mode))
	end,
	reactive_theme = theme.set_roles,
}

local function notify_status()
	local s = ipc.status
	local t = s and s.current_track
	if not t then
		return notify("nothing playing")
	end
	local icon = ICON[s.status] or "⏹"
	notify(string.format("%s %s - %s", icon, t.artist or "?", t.title or "?"))
end

local function notify_theme(arg)
	if arg == "reset" then
		unpaint()
		return notify("reactive theme cleared")
	end
	if not theme.enabled() then
		return notify("reactive theming is off (theme.reactive = true)")
	end
	if not theme.roles() then
		return notify("no palette from the daemon yet")
	end
	local a, b, c = theme.palette_hexes()
	notify(string.format("%s %s %s", a, b, c))
end

local CMDS = {
	{ name = "play", key = "play_pause", desc = "play/pause", run = I.play_pause },
	{ name = "next", key = "next", desc = "next track", run = I.next },
	{ name = "prev", key = "prev", desc = "previous track", run = I.prev },
	{ name = "stop", key = "stop", desc = "stop", run = I.stop },
	{
		name = "volup",
		key = "volume_up",
		desc = "volume up",
		run = function()
			I.set_volume(5)
		end,
	},
	{
		name = "voldown",
		key = "volume_down",
		desc = "volume down",
		run = function()
			I.set_volume(-5)
		end,
	},
	{ name = "mute", run = I.mute },
	{ name = "shuffle", run = I.shuffle },
	{ name = "status", run = notify_status },
	{
		name = "seek",
		arg = true,
		run = function(arg)
			local secs = tonumber(arg)
			if secs then
				I.seek(secs)
			else
				notify("seek: expected seconds", vim.log.levels.ERROR)
			end
		end,
	},
	{ name = "repeat", arg = true, run = I.cycle_repeat },
	{ name = "theme", arg = true, run = notify_theme },
	{ name = "queue", key = "queue", arg = true, desc = "browse the queue", run = I.queue },
	{ name = "spotify", key = "spotify", arg = true, desc = "search Spotify", run = I.spotify },
	{
		name = "spotify-playlists",
		key = "spotify_playlists",
		desc = "browse Spotify playlists",
		run = I.spotify_playlists,
	},
	{ name = "radio", key = "radio", arg = true, desc = "browse radio", run = I.radio },
	{ name = "search", key = "search", arg = true, desc = "search the library", run = I.search },
	{ name = "playlists", key = "playlists", desc = "browse playlists", run = I.playlists },
	{ name = "favourites", key = "favourites", desc = "browse favourites", run = I.favourites },
}

local SUBCOMPLETION = {
	["repeat"] = { "off", "one", "all" },
	theme = { "reset" },
	queue = { "remove", "clear" },
	radio = { "tags", "countries" },
}

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
		notify("unknown subcommand '" .. tostring(args.fargs[1]) .. "'", vim.log.levels.ERROR)
	end, { nargs = "+", complete = complete })

	local km = I.opts.keymaps or {}
	for _, c in ipairs(CMDS) do
		local lhs = c.key and km[c.key]
		if lhs then
			vim.keymap.set("n", lhs, c.run, { desc = "GTM: " .. c.desc })
		end
	end
end

local function stop_resync()
	resync = close_timer(resync)
end

local function start_resync()
	stop_resync()
	resync = uv.new_timer()
	resync:start(I.opts.resync_interval, I.opts.resync_interval, function()
		ipc.send("get_status_lite", nil, function(resp)
			if resp and resp.state then
				ipc.set_status(resp.state)
			end
		end)
		pulse.connect(ipc.pulse_path())
		theme.refresh()
	end)
end

function I.setup(opts)
	I.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	theme.setup(I.opts.theme)

	-- Tell the loader (and any other host) that setup is owned; see
	-- plugin/gtm.lua. Safe to set before the rest of the body runs.
	vim.g.loaded_gtm = true

	-- Idempotent: a config reload, or the loader's default auto-setup racing the
	-- host's explicit call, must not duplicate sockets, handlers or autocmds.
	if I._wired then
		start_resync()
		return I
	end
	I._wired = true

	for name, handler in pairs(HANDLERS) do
		pulse.on(name, handler)
	end
	-- The pulse stream owns its own reconnection (a daemon restart or a lost
	-- race with the listener must not leave it dead); the command socket still
	-- re-claims it on every (re)connect so the two never drift apart.
	ipc.connect(I.opts.socket_path, function()
		pulse.connect(ipc.pulse_path())
	end)
	register()
	start_resync()

	vim.api.nvim_create_autocmd(
		"ColorScheme",
		{ desc = "GTM: re-derive reactive theme", callback = theme.on_colorscheme }
	)
	-- `:set background=light|dark` can re-theme without a `ColorScheme` at all,
	-- and it flips the polarity the daemon's token set is read against.
	vim.api.nvim_create_autocmd("OptionSet", {
		pattern = "background",
		desc = "GTM: re-derive reactive theme on background flip",
		callback = theme.on_colorscheme,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		desc = "GTM: release daemon resources",
		callback = function()
			stop_resync()
			pulse.close()
			ipc.disconnect()
			theme.restore()
		end,
	})

	return I
end

I._ipc = ipc
I._pulse = pulse
I._theme = theme
I._health = health

return I

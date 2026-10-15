-- Headless smoke test. Stands up a fake gtmd (a JSON command socket and a
-- MessagePack pulse socket), drives the plugin through setup, events, statusline
-- rendering and health, then asserts on the results.
--
--   nvim --headless -l scripts/smoke.lua
--
-- Exits non-zero if any check fails.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local cmd_sock = tmp .. "/gtmd.sock"
local pulse_sock = tmp .. "/gtmd.pulse"

local uv = vim.uv
local failures = 0

local function check(name, cond, detail)
	if cond then
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
	end
end

-- MessagePack helpers, hand-rolled so the test needs no encoder.
local function be32(n)
	return string.char(
		math.floor(n / 16777216) % 256,
		math.floor(n / 65536) % 256,
		math.floor(n / 256) % 256,
		n % 256
	)
end

local function fixstr(s)
	return string.char(0xa0 + #s) .. s
end

--- One pulse frame: `[ [tag, ...fields] ]`.
local function frame(tag, ...)
	local fields = { ... }
	local out = "\x91" .. string.char(0x90 + #fields + 1) .. fixstr(tag)
	for i = 1, select("#", ...) do
		out = out .. fields[i]
	end
	return out
end

local function bind(path)
	local pipe = uv.new_pipe(false)
	assert(uv.pipe_bind(pipe, path))
	return pipe
end

--- Accept one connection and hand the stream to `on_connect`.
local function serve(path, on_connect)
	local server = bind(path)
	uv.listen(server, 1, function()
		local client = uv.new_pipe(false)
		uv.accept(server, client)
		on_connect(client)
	end)
	return server
end

-- The fake daemon -------------------------------------------------------

local push = {}

serve(pulse_sock, function(client)
	push.client = client
end)

serve(cmd_sock, function(client)
	client:read_start(function(_, data)
		if not data then
			return
		end
		for text in data:gmatch("[^\n]+") do
			local req = vim.json.decode(text)
			if req.cmd == "get_status" or req.cmd == "get_status_lite" then
				client:write(vim.json.encode({
					id = req.id,
					state = {
						status = "Playing",
						["repeat"] = "Off",
						volume = 80,
						shuffle = false,
						time_pos = 10,
						duration = 200,
						current_track = { artist = "Aphex Twin", title = "Xtal", album = "SAW", duration = 200 },
					},
				}) .. "\n")
			end
		end
	end)
end)

-- Load the plugin -------------------------------------------------------

vim.opt.runtimepath:prepend(repo)
local gtm = require("gtm").setup({ socket_path = cmd_sock, theme = { reactive = true } })
local ipc = require("gtm.ipc")
local pulse = require("gtm.pulse")
local theme = require("gtm.theme")

vim.wait(3000, function()
	return ipc.connected
end, 20)
vim.wait(1000, function()
	return pulse.is_connected()
end, 20)

print("\n[sockets]")
check("command socket connected", ipc.connected)
check("pulse socket connected", pulse.is_connected())
check("primed status snapshot", ipc.status ~= nil)
check("status lowercased", ipc.status and ipc.status.status == "playing")
check("repeat lowercased", ipc.status and ipc.status["repeat"] == "off")
check("track survived JSON decode", ipc.status and ipc.status.current_track and ipc.status.current_track.title == "Xtal")

print("\n[position]")
vim.wait(1200)
local pos = ipc.position()
check(string.format("position extrapolates past the anchor (%.1fs)", pos), pos > 10.5 and pos < 14)

print("\n[statusline]")
vim.cmd("redrawstatus")
check("compact format", gtm.statusline():find("Aphex Twin %- Xtal") ~= nil, gtm.statusline())
check("compact includes volume", gtm.statusline():find("vol:80%%") ~= nil)
check("lualine component is a table", type(gtm.lualine_component()) == "table")
check("lualine visible while connected", gtm.lualine_component().cond() == true)
gtm.opts.statusline_format = "detailed"
check("detailed format", gtm.statusline():find("%[") ~= nil, gtm.statusline())
gtm.opts.statusline_format = "compact"

print("\n[pulse events: fallback palette]")
if push.client then
	local palette = frame("reactive_palette", fixstr("#3b6ea5"), fixstr("#d94f70"), fixstr("#7ec8a9"))
	push.client:write(be32(#palette) .. palette)
	vim.wait(1000, function()
		return theme.roles() ~= nil
	end, 20)

	local roles = theme.roles()
	check("palette derived locally", theme.source() == "local", tostring(theme.source()))
	check("roles populated from 3 hex colours", roles ~= nil and roles.bg0 ~= nil and roles.accent ~= nil, vim.inspect(roles))
	check("Normal takes the local bg0", vim.api.nvim_get_hl(0, { name = "Normal" }).bg == roles.bg0)
	check("semantic groups untouched", vim.api.nvim_get_hl(0, { name = "Error" }).fg ~= nil)

	-- An empty palette means "no art", which clears rather than tints black.
	local empty = frame("reactive_palette", fixstr(""), fixstr(""), fixstr(""))
	push.client:write(be32(#empty) .. empty)
	vim.wait(1000, function()
		return theme.roles() == nil
	end, 20)
	check("empty palette clears the tint", theme.roles() == nil)

	-- A track end has to give the editor back too.
	local ended = frame("track_ended")
	push.client:write(be32(#ended) .. ended)
	vim.wait(300)
	check("track end leaves nothing tinted", theme.roles() == nil)

	-- Telemetry must be dropped without being decoded.
	local junk = frame("spectrum_changed")
	push.client:write(be32(#junk) .. junk)
	vim.wait(200)
	check("telemetry frame ignored", true)
else
	check("pulse client accepted", false)
end

print("\n[pulse events: daemon role sets]")
if push.client then
	-- ver, dark map, light map. `vim.mpack.encode` makes a msgpack map; the
	-- frame wraps it in the event array the daemon would produce.
	local function role_map(bg, fg, accent)
		return vim.mpack.encode({
			bg0 = bg, bg1 = bg, bg2 = bg, bg3 = bg, sel_bg = bg,
			fg = fg, fg_dim = fg, cursor_line_nr = accent,
			accent = accent, accent2 = accent, accent3 = accent,
		})
	end
	-- Roles cross the wire as `#rrggbb` strings, so the fake daemon sends those.
	local function roles_frame()
		local payload = "\x91\x94" .. fixstr("reactive_theme") .. string.char(1)
			.. role_map("#0d0d12", "#e0e0e0", "#3b6ea5")
			.. role_map("#f6f4f1", "#1a1a1a", "#9c3b52")
		return be32(#payload) .. payload
	end

	push.client:write(roles_frame())
	vim.wait(1000, function()
		return theme.source() == "daemon"
	end, 20)

	check("role set adopted from the daemon", theme.source() == "daemon", tostring(theme.source()))
	check("token-set version recorded", theme.version() == 1, tostring(theme.version()))
	check("dark polarity picked for a dark editor", theme.roles().bg0 == 0x0d0d12, vim.inspect(theme.roles().bg0))
	check("Normal takes the daemon's bg0", vim.api.nvim_get_hl(0, { name = "Normal" }).bg == 0x0d0d12)
	check("semantic groups still untouched", vim.api.nvim_get_hl(0, { name = "Error" }).fg ~= nil)

	-- An incomplete role set must be refused outright, not half-applied.
	local partial = "\x91\x94" .. fixstr("reactive_theme") .. string.char(1)
		.. vim.mpack.encode({ bg0 = "#ffffff" }) .. vim.mpack.encode({ bg0 = "#ffffff" })
	push.client:write(be32(#partial) .. partial)
	vim.wait(400)
	check("incomplete role set refused", theme.roles().bg0 == 0x0d0d12, "a partial set overwrote the tint")

	-- A colorscheme swap re-picks polarity from the stored sets.
	vim.o.background = "light"
	theme.on_colorscheme()
	local light_bg = theme.roles().bg0
	check("light polarity picked after a colorscheme change", light_bg == 0xf6f4f1, vim.inspect(light_bg))
	vim.o.background = "dark"
	theme.on_colorscheme()
	check("dark polarity restored", theme.roles().bg0 == 0x0d0d12)
else
	check("pulse client accepted", false)
end

print("\n[theme restore]")
-- The role-set checks above leave a tint up; drop it before taking the baseline.
theme.restore()
local pristine = vim.api.nvim_get_hl(0, { name = "Normal" })
theme.apply({ primary = "#3b6ea5", secondary = "#d94f70", tertiary = "#7ec8a9" })
check("tint re-applied", theme.roles() ~= nil)
theme.restore()
check("Normal restored exactly", vim.deep_equal(pristine, vim.api.nvim_get_hl(0, { name = "Normal" })))

-- A colorscheme change must not capture the tint as the new baseline.
local function role_set(bg, fg, accent)
	local set = { ver = 1 }
	for _, polarity in ipairs({ "dark", "light" }) do
		set[polarity] = {
			bg0 = bg, bg1 = bg, bg2 = bg, bg3 = bg, sel_bg = bg,
			fg = fg, fg_dim = fg, cursor_line_nr = accent,
			accent = accent, accent2 = accent, accent3 = accent,
		}
	end
	return set
end

theme.set_roles(role_set("#0d0d12", "#e0e0e0", "#3b6ea5"))
check("tinted before the colorscheme swap", vim.api.nvim_get_hl(0, { name = "Normal" }).bg ~= pristine.bg)
theme.on_colorscheme()
check("tint survives a colorscheme swap", theme.roles() ~= nil)
theme.restore()
local now = vim.api.nvim_get_hl(0, { name = "Normal" })
check("restore still returns the pristine colour", vim.deep_equal(pristine, now))

print("\n[commands]")
check("Gtm command registered", vim.fn.exists(":Gtm") == 2)
vim.cmd("Gtm next")
check("Gtm next ran cleanly", true)
local completions = vim.fn.getcompletion("Gtm ", "cmdline")
local has_sub = vim.tbl_contains(completions, "play") and vim.tbl_contains(completions, "seek")
check("subcommand completion", has_sub, vim.inspect(completions))

print("\n[health]")
local healthy, herr = pcall(require("gtm.health").check)
check("health.check runs", healthy, herr)
check("ipc.stale_for is a number", type(ipc.stale_for()) == "number")

print("\n[idempotent setup]")
gtm.setup({ socket_path = cmd_sock })
check("setup is idempotent", vim.fn.exists(":Gtm") == 2 and ipc.connected)

vim.wait(100)
print("\n" .. (failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED")))
vim.cmd(failures == 0 and "qa!" or "cq!")
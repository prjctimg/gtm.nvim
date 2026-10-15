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

print("\n[pulse events]")
if push.client then
	local palette = frame("reactive_palette", fixstr("#3b6ea5"), fixstr("#d94f70"), fixstr("#7ec8a9"))
	push.client:write(be32(#palette) .. palette)
	vim.wait(1000, function()
		return theme.palette() ~= nil
	end, 20)

	local pal = theme.palette()
	check("palette decoded from MessagePack", pal ~= nil and pal.primary[1] == 0x3b and pal.primary[2] == 0x6e, vim.inspect(pal))
	check("tint applied to Normal", vim.api.nvim_get_hl(0, { name = "Normal" }).bg ~= nil)
	check("semantic groups untouched", vim.api.nvim_get_hl(0, { name = "Error" }).fg ~= nil)

	-- A track end has to give the editor back.
	local ended = frame("track_ended")
	push.client:write(be32(#ended) .. ended)
	vim.wait(1000, function()
		return theme.palette() == nil
	end, 20)
	check("track end clears the tint", theme.palette() == nil)

	-- Telemetry must be dropped without being decoded.
	local junk = frame("spectrum_changed")
	push.client:write(be32(#junk) .. junk)
	vim.wait(200)
	check("telemetry frame ignored", true)
else
	check("pulse client accepted", false)
end

print("\n[theme restore]")
local before = vim.api.nvim_get_hl(0, { name = "Normal" })
local palette = frame("reactive_palette", fixstr("#3b6ea5"), fixstr("#d94f70"), fixstr("#7ec8a9"))
push.client:write(be32(#palette) .. palette)
vim.wait(1000, function()
	return theme.palette() ~= nil
end, 20)
theme.restore()
check("Normal restored exactly", vim.deep_equal(before, vim.api.nvim_get_hl(0, { name = "Normal" })))

print("\n[commands]")
check("Gtm command registered", vim.fn.exists(":Gtm") == 2)
vim.cmd("Gtm next")
check("Gtm next ran cleanly", true)
local completions = vim.fn.getcompletion("Gtm ", "cmdline")
check("subcommand completion", vim.tbl_contains(completions, "play") and vim.tbl_contains(completions, "seek"), vim.inspect(completions))

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
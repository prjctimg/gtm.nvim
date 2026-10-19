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

-- Defaults: the source marker and the state icon only.
check("default renders the state icon alone", gtm.statusline() == "▶", vim.inspect(gtm.statusline()))
check("default hides artist and title", not gtm.statusline():find("Aphex"))
check("default hides volume", not gtm.statusline():find("vol:"))
check("default sets no keymaps", next(gtm.opts.keymaps) == nil)

-- Opt-in items, each independent.
local defaults_statusline = vim.deepcopy(gtm.opts.statusline)
local function with(opts)
	gtm.opts.statusline = vim.tbl_extend("force", gtm.opts.statusline, opts)
	local out = gtm.statusline()
	gtm.opts.statusline = vim.deepcopy(defaults_statusline)
	return out
end

check("artist is opt-in", with({ artist = true }):find("Aphex Twin") ~= nil)
check("title is opt-in", with({ title = true }):find("Xtal") ~= nil)
check("volume is opt-in", with({ volume = true }):find("vol:80%%") ~= nil)
check("time is opt-in", with({ time = true }):find("%[%d%d:%d%d/%d%d:%d%d%]") ~= nil)
check("progress is opt-in", with({ progress = true }):find("━") ~= nil)
check("repeat is opt-in and off by default", with({ ["repeat"] = true }) == "▶", with({ ["repeat"] = true }))
check("album is opt-in", with({ album = true }):find("SAW") ~= nil)

-- lualine renders exactly what statusline() renders — one path, no format split.
local component = gtm.lualine_component()
check("lualine component is a table", type(component) == "table")
check("lualine visible while connected", component.cond() == true)
check("lualine renders the same as statusline()", component[1]() == gtm.statusline())

-- 0.1.x compatibility: a statusline_format config maps onto the item table.
local migrated = require("gtm").setup({ statusline_format = "compact" }).opts.statusline
check("statusline_format=compact migrates to off", migrated.artist == false and migrated.state == true, vim.inspect(migrated))
local migrated_dense = require("gtm").setup({ statusline_format = "detailed" }).opts.statusline
check("statusline_format=detailed migrates to on", migrated_dense.artist == true and migrated_dense.volume == true, vim.inspect(migrated_dense))
gtm.opts.statusline = vim.deepcopy(defaults_statusline)

-- Empty state is a bare stop icon, whatever is enabled.
ipc.clear()
check("empty state is the stop icon alone", gtm.statusline() == "⏹", vim.inspect(gtm.statusline()))
ipc.set_status({ status = "Playing", volume = 80, time_pos = 10, duration = 200, current_track = { artist = "Aphex Twin", title = "Xtal", album = "SAW", duration = 200 } })

print("\n[source icons]")
-- Nerd Font codepoints are UTF-8 encoded literals, not \u escapes: LuaJIT
-- parses \u{...} without error and yields the wrong bytes.
local icons = gtm.opts.statusline.icons
local EXPECT = {
	spotify = "\xf3\xb0\x93\x87", -- md-spotify      U+F04C7
	radio = "\xf3\xb0\x90\xb9", -- md-radio        U+F0439
	podcast = "\xf3\xb0\xa6\x94", -- md-podcast      U+F0994
	["local"] = "\xf3\xb1\x8d\x99", -- md-folder_music U+F1359
	chart = "\xf3\xb0\x84\xaa", -- md-chart_line   U+F012A
}
local wrong = {}
for src, want in pairs(EXPECT) do
	ipc.status.source = src
	local got = gtm.statusline()
	if not got:find(want, 1, true) then
		wrong[#wrong + 1] = src .. " (" .. vim.inspect(icons[src]) .. ")"
	end
end
check("each source renders its codepoint", #wrong == 0, table.concat(wrong, ", "))

ipc.status.source = "navidrome"
check("an unknown source renders nothing", gtm.statusline() == "▶", vim.inspect(gtm.statusline()))

icons.radio = "R"
ipc.status.source = "radio"
check("icons are overridable", gtm.statusline() == "R ▶", vim.inspect(gtm.statusline()))
gtm.opts.statusline = vim.deepcopy(defaults_statusline)
ipc.status.source = nil
check("no source field renders nothing", gtm.statusline() == "▶", vim.inspect(gtm.statusline()))

print("\n[pulse events: a bare palette tints nothing]")
if push.client then
	-- reactive_palette carries three hex strings. The plugin has no local
	-- derivation left, so a daemon that sends only this tints nothing at all
	-- rather than guessing colours the TUI would render differently.
	local palette = frame("reactive_palette", fixstr("#3b6ea5"), fixstr("#d94f70"), fixstr("#7ec8a9"))
	push.client:write(be32(#palette) .. palette)
	vim.wait(300)
	check("a bare palette is ignored", theme.roles() == nil, vim.inspect(theme.roles()))

	-- A track end has to give the editor back.
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
			-- The syntax and surface roles the client now consumes: distinct
			-- values so a group that fell through to `fg` is visible.
			comment = "#7a6478", string = "#8fbf84", keyword = "#c99be8",
			["function"] = "#82c8f0", type = "#7fd6d0", constant = "#f0b076",
			operator = "#a8b0c0", punctuation = "#9a9aa8",
			search_bg = "#5c4a3a", search_fg = "#1a1a10",
			sel_fg = "#f2f2f6", line = "#5a4463",
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
		return theme.roles() ~= nil
	end, 20)

	check("token-set version recorded", theme.version() == 1, tostring(theme.version()))
	check("dark polarity picked for a dark editor", theme.roles().bg0 == 0x0d0d12, vim.inspect(theme.roles().bg0))
	local function fg(name) return vim.api.nvim_get_hl(0, { name = name }).fg end
	check("Normal is a wash, not the daemon's flat surface",
		vim.api.nvim_get_hl(0, { name = "Normal" }).bg ~= 0x0d0d12,
		vim.inspect(vim.api.nvim_get_hl(0, { name = "Normal" })))
	check("Comment takes the comment role, not fg_dim", fg("Comment") == 0x7a6478, tostring(fg("Comment")))
	check("String takes the string role", fg("String") == 0x8fbf84, tostring(fg("String")))
	check("Keyword takes the keyword role", fg("Keyword") == 0xc99be8, tostring(fg("Keyword")))
	check("a tree-sitter capture follows its base group", fg("@function.builtin") == 0x82c8f0, tostring(fg("@function.builtin")))
	check("syntax groups are not all one colour",
		fg("String") ~= fg("Keyword") and fg("Keyword") ~= fg("Function"),
		vim.inspect({ fg("String"), fg("Keyword"), fg("Function") }))
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

	-- gtmd batches these two into a single frame, palette first — the shape a
	-- test that writes them separately cannot see. The palette is deliberately
	-- not in WANTED, so decoding must read past its leading tag rather than
	-- deciding the frame is not for us and dropping the theme behind it.
	theme.clear()
	check("cleared before the batch", theme.roles() == nil)
	local batch = "\x92"
		.. string.char(0x94) .. fixstr("reactive_palette")
		.. fixstr("#3c044c") .. fixstr("#24042c") .. fixstr("#2b1618")
		.. string.char(0x94) .. fixstr("reactive_theme") .. string.char(1)
		.. role_map("#0d0d12", "#e0e0e0", "#3b6ea5")
		.. role_map("#f6f4f1", "#1a1a1a", "#9c3b52")
	push.client:write(be32(#batch) .. batch)
	vim.wait(1000, function()
		return theme.roles() ~= nil
	end, 20)
	check("a batched palette+theme frame keeps its theme", theme.roles() ~= nil, vim.inspect(theme.roles()))
else
	check("pulse client accepted", false)
end

print("\n[theme restore]")
-- The role-set checks above leave a tint up; drop it before taking the baseline.
theme.restore()
local pristine = vim.api.nvim_get_hl(0, { name = "Normal" })
theme.set_roles({
	ver = 1,
	dark = { bg0 = "#3b6ea5", bg1 = "#3b6ea5", bg2 = "#3b6ea5", bg3 = "#3b6ea5", sel_bg = "#3b6ea5", fg = "#e0e0e0", fg_dim = "#e0e0e0", cursor_line_nr = "#3b6ea5", accent = "#3b6ea5", accent2 = "#3b6ea5", accent3 = "#3b6ea5" },
	light = { bg0 = "#f6f4f1", bg1 = "#f6f4f1", bg2 = "#f6f4f1", bg3 = "#f6f4f1", sel_bg = "#f6f4f1", fg = "#1a1a1a", fg_dim = "#1a1a1a", cursor_line_nr = "#9c3b52", accent = "#9c3b52", accent2 = "#9c3b52", accent3 = "#9c3b52" },
})
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
check("restore keeps the role sets so a re-pick is possible", theme.version() == 1)

-- A reset must forget them, or the next colorscheme change resurrects a tint
-- the user just turned off.
theme.set_roles(role_set("#0d0d12", "#e0e0e0", "#3b6ea5"))
vim.cmd("Gtm theme reset")
theme.on_colorscheme()
check("a reset is not resurrected by a colorscheme change", theme.roles() == nil, vim.inspect(theme.roles()))

print("\n[commands]")
check("Gtm command registered", vim.fn.exists(":Gtm") == 2)
vim.cmd("Gtm next")
check("Gtm next ran cleanly", true)
local completions = vim.fn.getcompletion("Gtm ", "cmdline")
local has_sub = vim.tbl_contains(completions, "play") and vim.tbl_contains(completions, "seek")
check("subcommand completion", has_sub, vim.inspect(completions))

-- Every subcommand runs without raising. This is the surface that broke when a
-- helper was renamed under one caller and not another.
local subcommands = { "play", "next", "prev", "stop", "volup", "voldown", "mute", "shuffle", "status", "theme", "seek 30", "repeat one", "repeat", "theme reset" }
local broken = {}
for _, sub in ipairs(subcommands) do
	local ok, err = pcall(vim.cmd, "Gtm " .. sub)
	if not ok then
		broken[#broken + 1] = sub .. " -> " .. tostring(err)
	end
end
check("every subcommand runs", #broken == 0, table.concat(broken, " | "))

-- `:Gtm theme` is the one that reads back the live tint; a nil helper here is
-- invisible until a user runs it.
theme.set_roles({
	ver = 1,
	dark = { bg0 = "#3b6ea5", bg1 = "#3b6ea5", bg2 = "#3b6ea5", bg3 = "#3b6ea5", sel_bg = "#3b6ea5", fg = "#e0e0e0", fg_dim = "#e0e0e0", cursor_line_nr = "#3b6ea5", accent = "#3b6ea5", accent2 = "#3b6ea5", accent3 = "#3b6ea5" },
	light = { bg0 = "#f6f4f1", bg1 = "#f6f4f1", bg2 = "#f6f4f1", bg3 = "#f6f4f1", sel_bg = "#f6f4f1", fg = "#1a1a1a", fg_dim = "#1a1a1a", cursor_line_nr = "#9c3b52", accent = "#9c3b52", accent2 = "#9c3b52", accent3 = "#9c3b52" },
})
local real_notify = vim.notify
local function capture(...)
	local seen = {}
	vim.notify = function(msg)
		seen[#seen + 1] = tostring(msg)
	end
	local results = { pcall(...) }
	vim.notify = real_notify
	return seen, results
end

local seen = capture(vim.cmd, "Gtm theme")
check(":Gtm theme reports the live palette", #seen == 1 and seen[1]:find("^%[gtm%] #%x%x%x%x%x%x ") ~= nil, vim.inspect(seen))
vim.cmd("Gtm theme reset")
check(":Gtm theme reset clears the tint", theme.roles() == nil)

-- Bad arguments must be reported, not sent.
seen = capture(vim.cmd, "Gtm seek notanumber")
check("bad :Gtm seek is reported, and only once", #seen == 1 and seen[1]:find("expected seconds") ~= nil, vim.inspect(seen))
seen = capture(vim.cmd, "Gtm bogus")
check("unknown subcommand is reported", #seen == 1 and seen[1]:find("unknown subcommand") ~= nil, vim.inspect(seen))

print("\n[health]")
local healthy, herr = pcall(require("gtm.health").check)
check("health.check runs", healthy, herr)
check("ipc.stale_for is a number", type(ipc.stale_for()) == "number")

print("\n[idempotent setup]")
gtm.setup({ socket_path = cmd_sock })
check("setup is idempotent", vim.fn.exists(":Gtm") == 2 and ipc.connected)

-- A disconnect racing an in-flight connect used to close the pipe twice, a uv
-- error raised *inside* the connect callback — where pcall cannot see it. It
-- only showed when quitting nvim while it was still dialling a daemon that was
-- down. Run the race in a child nvim and read its stderr.
local race = tmp .. "/race.lua"
vim.fn.writefile({
	"vim.opt.runtimepath:prepend([[" .. repo .. "]])",
	'local ipc = require("gtm.ipc")',
	'ipc.connect([[' .. cmd_sock .. "]], function() end)",
	"ipc.disconnect()",
	"vim.wait(600)",
}, race)
local res = vim.system({ vim.v.progpath, "--headless", "-l", race }, { text = true }):wait()
check("no double-close when a connect is torn down mid-flight", not (res.stderr or ""):find("already closing", 1, true), vim.inspect(res.stderr))

vim.wait(100)
print("\n" .. (failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED")))
vim.cmd(failures == 0 and "qa!" or "cq!")
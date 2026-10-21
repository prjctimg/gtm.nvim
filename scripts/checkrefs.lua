-- Static cross-module reference check.
--
--   nvim --headless -l scripts/checkrefs.lua
--
-- The plugin is one module (`lua/gtm/init.lua`); it exposes its internal
-- tables as `_ipc`, `_pulse` and `_theme`. This script resolves every
-- `ipc.field(` / `pulse.field(` / `theme.field(` call in the sources against
-- those tables as they actually load, so a renamed or deleted helper that one
-- caller missed is a failure at push rather than an error a user hits. Field
-- *reads* (`ipc.status`) are allowed to be nil; only calls are checked, because
-- those are the ones that break.
--
-- Exits non-zero on any unresolved call.

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local ok, gtm = pcall(require, "gtm")
if not ok then
	print("FAIL cannot load gtm: " .. tostring(gtm))
	vim.cmd("cq!")
end

local loaded = { ipc = gtm._ipc, pulse = gtm._pulse, theme = gtm._theme }
for name, mod in pairs(loaded) do
	if type(mod) ~= "table" then
		print("FAIL gtm._" .. name .. " is not a table")
		vim.cmd("cq!")
	end
end

local sources = { "lua/gtm/init.lua", "lua/gtm/health.lua" }
local failures = 0

for _, rel in ipairs(sources) do
	local lines = vim.fn.readfile(root .. "/" .. rel)
	for no, line in ipairs(lines) do
		-- Strip comments so a renamed function in prose is not flagged. The
		-- leading space plus the boundary class keep a prefix such as
		-- `my_ipc.send` from matching the `ipc` table.
		local code = " " .. line:gsub("%-%-.*$", "")
		for name, mod in pairs(loaded) do
			for field in code:gmatch("[^%w_%.]" .. name .. "%.([%a_][%w_]*)%s*%(") do
				if type(mod[field]) ~= "function" then
					print(string.format("FAIL %s:%d  %s.%s is not a function", rel, no, name, field))
					failures = failures + 1
				end
			end
		end
	end
end

print(failures == 0 and "all cross-module calls resolve" or (failures .. " unresolved call(s)"))
vim.cmd(failures == 0 and "qa!" or "cq!")

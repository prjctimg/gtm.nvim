-- Static cross-module reference check.
--
--   nvim --headless -l scripts/checkrefs.lua
--
-- Resolves every `module.field` access against the module table as it actually
-- loads, so a renamed or deleted helper that one caller missed is a failure at
-- push rather than an error a user hits. Field *reads* (`ipc.status`) are
-- allowed to be nil; only calls (`ipc.send(`) are checked, because those are the
-- ones that break.
--
-- Exits non-zero on any unresolved call.

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local MODULES = { ipc = "gtm.ipc", pulse = "gtm.pulse", theme = "gtm.theme" }
local loaded = {}

for name, path in pairs(MODULES) do
	local ok, mod = pcall(require, path)
	if not ok then
		print("FAIL cannot load " .. path .. ": " .. tostring(mod))
		vim.cmd("cq!")
	end
	loaded[name] = mod
end

local sources = { "lua/gtm/init.lua", "lua/gtm/health.lua" }
local failures = 0

for _, rel in ipairs(sources) do
	local lines = vim.fn.readfile(root .. "/" .. rel)
	for no, line in ipairs(lines) do
		-- Strip comments so a renamed function in prose is not flagged.
		local code = line:gsub("%-%-.*$", "")
		for name, mod in pairs(loaded) do
			for field in code:gmatch(name .. "%.([%a_][%w_]*)%s*%(") do
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
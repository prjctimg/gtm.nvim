-- luacheck configuration for gtm.nvim (Neovim LuaJIT)
std = "lua51"

-- Neovim runtime/API globals.
read_globals = {
	"vim",
}

-- W122: `vim.bo[buf].buftype = ...`, `vim.bo.modifiable = ...` etc. are the
-- standard Neovim buffer-option idioms; luacheck treats vim.bo as a read-only
-- field of the global.
ignore = {
	"122", -- setting read-only field of global vim (vim.bo idiom)
}
max_line_length = 120
-- luacheck configuration for gtm.nvim (Neovim Lua 5.1)
std = "lua51"

-- Neovim runtime/API globals.
read_globals = {
	"vim",
}

-- W122: `vim.bo[buf].buftype = ...`, `vim.bo.modifiable = ...` etc. are the
-- standard Neovim buffer-option idioms; luacheck treats vim.bo as a
-- read-only field of the global.
-- W214: this plugin's convention names used config arguments `_opts`
-- (unused-hint prefix) consistently across float/statusline/setup.
ignore = {
	"122", -- setting read-only field of global vim (vim.bo idiom)
	"214", -- used variable `_opts` with unused hint (repo convention)
}
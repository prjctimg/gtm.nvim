-- gtm.nvim loader
-- Auto-setup with defaults when loaded manually (not via lazy.nvim) and when
-- the host has not already taken over configuration.
--
-- Opt out (recommended when calling `require('gtm').setup(opts)` yourself):
-- set `vim.g.loaded_gtm = true` *before* the plugin loads (e.g. before
-- `vim.pack.add`/`packadd`). `I.setup()` also sets the flag, so any ordering
-- between the loader's VeryLazy auto-setup and the host's explicit setup ends
-- with exactly one full registration using the host's options.
if not vim.g.loaded_gtm then
	vim.api.nvim_create_autocmd("User", {
		pattern = "VeryLazy",
		once = true,
		callback = function()
			-- The host may have taken over setup between plugin load and the
			-- VeryLazy event; re-check so a stray default setup never clobbers
			-- host options.
			if vim.g.loaded_gtm then
				return
			end
			if pcall(require, "lazy") then
				return
			end
			vim.g.loaded_gtm = true
			require("gtm").setup({})
		end,
	})
end
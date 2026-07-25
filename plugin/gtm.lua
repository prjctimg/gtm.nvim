-- gtm.nvim loader
-- Auto-setup with defaults when loaded manually (not via lazy.nvim).
if not vim.g.loaded_gtm then
  vim.g.loaded_gtm = true
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    callback = function()
      if not pcall(require, "lazy") then
        require("gtm").setup({})
      end
    end,
  })
end

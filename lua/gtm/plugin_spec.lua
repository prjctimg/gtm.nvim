return {
  "prjctimg/gtm.nvim",
  dependencies = {},
  event = "VeryLazy",
  cmd = { "Gtm" },
  opts = {
    socket_path = nil,
    statusline_format = "compact",
    statusline_interval = 1000,
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
      cover_art = true, -- requires 3rd/image.nvim
    },
    keymaps = {
      play_pause = "<leader>gp",
      next = "<leader>gn",
      prev = "<leader>gN",
      volume_up = "<leader>g>",
      volume_down = "<leader>g<",
      float = "<leader>gf",
      stop = "<leader>gS",
    },
  },
  config = function(_, opts)
    require("gtm").setup(opts)
  end,
}

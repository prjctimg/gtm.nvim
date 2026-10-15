-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- lazy.nvim spec. Defaults mirror gtm/init.lua; anything omitted here falls
-- back to the values the plugin ships with.
--
-- This is free software released under the GPL-3.0 license.

return {
	"prjctimg/gtm.nvim",
	event = "VeryLazy",
	cmd = "Gtm",
	opts = {
		statusline_format = "compact", -- "compact" | "detailed"
		resync_interval = 30000,
		theme = { reactive = false, extra_groups = {} },
		keymaps = {
			play_pause = "<leader>gp",
			next = "<leader>gn",
			prev = "<leader>gN",
			volume_up = "<leader>g>",
			volume_down = "<leader>g<",
			stop = "<leader>gS",
		},
	},
	config = function(_, opts)
		require("gtm").setup(opts)
	end,
}
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
		resync_interval = 30000,
		-- Statusline items, rendered in table order. Default shows the source
		-- marker and the state icon; the rest are opt-in.
		statusline = {
			source = true,
			state = true,
			artist = false,
			title = false,
			album = false,
			progress = false,
			time = false,
			volume = false,
			["repeat"] = false,
			shuffle = false,
		},
		theme = { reactive = true, extra_groups = {} },
		-- No keymaps by default. Suggestions are in the README; copy the ones
		-- you want.
		keymaps = {
			-- play_pause = "<leader>gp",
			-- next = "<leader>gn",
			-- prev = "<leader>gN",
			-- volume_up = "<leader>g>",
			-- volume_down = "<leader>g<",
			-- stop = "<leader>gS",
		},
	},
	config = function(_, opts)
		require("gtm").setup(opts)
	end,
}
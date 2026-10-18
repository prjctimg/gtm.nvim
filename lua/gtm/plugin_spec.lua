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
			-- Source markers: Nerd Font, Material Design Icons (Plane 15 PUA).
			-- Override with plain Unicode if your terminal has no patched font.
			icons = {
				spotify = "\xf3\xb0\x93\x87", -- md-spotify      U+F04C7
				radio = "\xf3\xb0\x90\xb9", -- md-radio        U+F0439
				podcast = "\xf3\xb0\xa6\x94", -- md-podcast      U+F0994
				["local"] = "\xf3\xb1\x8d\x99", -- md-folder_music U+F1359
				chart = "\xf3\xb0\x84\xaa", -- md-chart_line   U+F012A
			},
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
return {
	"prjctimg/gtm.nvim",
	dependencies = {
		-- Optional: cover art rendering in the float window. gtm.nvim works
		-- without it; only the artwork panel is skipped.
		{ "3rd/image.nvim", optional = true },
	},
	event = "VeryLazy",
	cmd = { "Gtm" },
	opts = {
		socket_path = nil,
		statusline_format = "compact",
		resync_interval = 30000,
		float = {
			width = 0.8,
			height = 0.8,
			border = "rounded",
			cover_art = true, -- requires 3rd/image.nvim
		},
		-- Reactive theming: tint layout highlights from the album art.
		theme = {
			reactive = false,
			intensity = 0.2,
			extra_groups = {},
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

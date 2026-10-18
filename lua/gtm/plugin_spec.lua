-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- lazy.nvim spec.
--
-- `opts` is deliberately empty: `setup()` deep-merges whatever arrives over the
-- defaults in lua/gtm/init.lua, so restating them here was duplicated truth that
-- had to be kept in step. The README is the single list of options.
--
-- This is free software released under the GPL-3.0 license.

return {
	"prjctimg/gtm.nvim",
	event = "VeryLazy",
	cmd = "Gtm",
	opts = {},
	config = function(_, opts)
		require("gtm").setup(opts)
	end,
}
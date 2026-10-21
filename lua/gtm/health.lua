-- Copyright (c) 2026 - present
-- Author: prjctimg <prjctimg@outlook.com>
-- gtm.health: `:checkhealth gtm` discovery shim
--
-- Neovim finds health checks by module path, so this file stays a thin forwarder
-- while the checks themselves live in `gtm.init`.
--
-- This is free software released under the GPL-3.0 license.

return {
	check = function()
		require("gtm")._health.check()
	end,
}

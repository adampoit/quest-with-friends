-- Run from the repository root: luajit tools/reproduce_sync_outage.lua [disconnect|throttle|combined]
local outage = require("tests.support.sync_outage")
for _, variant in ipairs(arg[1] and { arg[1] } or { "disconnect", "throttle", "combined" }) do
	print(outage.report(outage.run(variant)))
	print()
end

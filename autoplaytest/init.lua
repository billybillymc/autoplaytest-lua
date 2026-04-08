-- autoplaytest/init.lua — Engine-agnostic automated playtesting for Lua games
--
-- Usage:
--   local Autoplaytest = require("autoplaytest")
--   local Bot = Autoplaytest.Bot
--   local Telemetry = Autoplaytest.Telemetry

local Autoplaytest = {}

Autoplaytest.Bot = require("autoplaytest.bot")
Autoplaytest.Telemetry = require("autoplaytest.telemetry")

Autoplaytest._VERSION = "0.2.0"

return Autoplaytest

-- autoplaytest/init.lua — Entry point for the autoplaytest-lua library
--
-- Engine-agnostic automated playtesting framework for Lua games.
--
-- Usage:
--   local Autoplaytest = require("autoplaytest")
--   local Bot = Autoplaytest.Bot
--   local Telemetry = Autoplaytest.Telemetry

local Autoplaytest = {}

Autoplaytest.Bot = require("autoplaytest.bot")
Autoplaytest.Telemetry = require("autoplaytest.telemetry")

Autoplaytest._VERSION = "0.1.0"

return Autoplaytest

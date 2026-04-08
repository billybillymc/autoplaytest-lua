-- bot_apt.lua — Bridge: autoplaytest-lua library <-> Food Security game
--
-- Drop-in replacement for bot.lua that uses the autoplaytest library
-- for cursor simulation and telemetry, while keeping game-specific
-- strategy logic here.

local G = require("game")
local APT = require("autoplaytest")
local Bot = APT.Bot
local T = APT.Telemetry

-- Configure bot for this game's design resolution
Bot.screenW = G.DESIGN_W
Bot.screenH = G.DESIGN_H
Bot.maxDay = 15  -- force game over after this day (nil = no limit)

------------------------------------------------------
-- TARGETING: find the closest fly to the cursor
------------------------------------------------------

Bot.findTarget = function()
    if G.waveCompleteTimer > 0 then return nil end
    if #G.flies == 0 then return nil end

    local bestX, bestY, bestDist = nil, nil, math.huge
    for _, f in ipairs(G.flies) do
        local dx = f.x - Bot.cx
        local dy = f.y - Bot.cy
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < bestDist then
            bestX, bestY, bestDist = f.x, f.y, dist
        end
    end
    return bestX, bestY
end

------------------------------------------------------
-- CLICKING: dispatch into the game's input system
------------------------------------------------------

Bot.onClick = function(x, y)
    local Input = require("input")
    Input.handleWave(x, y)
end

------------------------------------------------------
-- GAME STATE ROUTING
------------------------------------------------------

Bot.getState = function()
    -- Force game over at day limit (for faster batch testing)
    if Bot.maxDay and G.day > Bot.maxDay and G.state == "wave" then
        G.freshness = 0
    end
    if G.state == "wave" then return "play"
    else return G.state end
end

------------------------------------------------------
-- STATE HANDLERS (non-wave states)
------------------------------------------------------

Bot.stateHandlers = {
    upgrade = function(dt, bot)
        local Wave = require("wave")
        local choices = G.upgradeChoices
        if #choices == 0 then return end

        local pick = math.random(#choices)

        -- Strategy: prioritize sustain when low freshness
        if G.freshness < 55 then
            for i, u in ipairs(choices) do
                if u.name == "Fresh Wax" or u.name == "Preservatives" then
                    pick = i; break
                end
            end
        end

        local chosen = choices[pick]
        chosen.apply()
        G.notification = { text = chosen.name .. "!", timer = 1.0 }
        T.log("upgrade", { name = chosen.name, freshness = G.freshness, day = G.day })
        Wave.showPath()
    end,

    path = function(dt, bot)
        local Wave = require("wave")
        if #G.pathChoices == 0 then return end

        local choice = 1
        -- Strategy: rest if low, battle otherwise
        if G.freshness < 45 then
            for i, p in ipairs(G.pathChoices) do
                if p == "rest" then choice = i; break end
            end
        else
            for i, p in ipairs(G.pathChoices) do
                if p == "battle" then choice = i; break end
            end
        end

        local chosen = G.pathChoices[choice]
        T.log("path", { pathType = chosen, freshness = G.freshness, day = G.day })

        if chosen == "battle" or chosen == "elite" then
            Wave.startWave(chosen)
        elseif chosen == "rest" then
            local Passives = require("passives")
            G.day = G.day + 1
            local heal = 15 + Passives.onRestBonus()
            G.freshness = math.min(G.maxFreshness, G.freshness + heal)
            Wave.showPath()
        elseif chosen == "mystery" then
            Wave.resolveMystery()
        end
    end,

    mystery_result = function(dt, bot)
        -- just wait, the mystery timer handles the transition
    end,

    gameover = function(dt, bot)
        bot.handleRunEnd(dt)
    end,

    title = function(dt, bot)
        bot.handleRunEnd(dt)
    end,

    select = function(dt, bot)
        bot.handleRunEnd(dt)
    end,
}

------------------------------------------------------
-- RUN LIFECYCLE
------------------------------------------------------

Bot.onRunStart = function()
    local Wave = require("wave")
    local Passives = require("passives")
    local Combo = require("combo")

    G.resetGame()
    Passives.apply()
    Combo.clear()

    -- Reset library telemetry
    T.reset()
    T.playerTag = "bot_" .. Bot.skill

    -- Set up game-specific telemetry hooks
    T.snapshotFn = function()
        return {
            freshness = G.freshness,
            flyCount = #G.flies,
            day = G.day,
            score = G.score,
        }
    end

    T.summaryFn = function()
        return {
            produce = G.selectedProduce,
            finalDay = G.day,
            finalScore = G.score,
            finalFreshness = G.freshness,
        }
    end

    Bot.cx = G.DESIGN_W / 2
    Bot.cy = G.DESIGN_H / 2
    Wave.startWave("battle")
end

Bot.onRunEnd = function()
    -- Log game over event and finalize telemetry
    T.log("game_over", {
        day = G.day, score = G.score,
        freshness = G.freshness,
        produce = G.selectedProduce,
    })
    T.outputFile = "apt_telemetry.lua"
    T.endRun()

    -- Print batch stats on final run
    if Bot.runsLeft <= 0 then
        print("\n" .. T.formatBatchStats())
        if #T.assertions > 0 then
            print("\n" .. T.formatAssertions())
        end
    end
end

------------------------------------------------------
-- BALANCE ASSERTIONS (example — customize per game)
------------------------------------------------------

T.addAssertion("bot_medium survives past day 3", function(run)
    return (run.finalDay or 0) >= 3
end)

T.addAssertion("bot_high survives past day 8", function(run)
    if run.player ~= "bot_high" then return true end  -- skip for other skills
    return (run.finalDay or 0) >= 8
end)

------------------------------------------------------
-- WAVE PHASE TRACKING
-- Hook into the game's wave start/end to use library phase tracking
------------------------------------------------------

-- We'll patch the Wave module's startWave and showUpgrades to add phase tracking
local _patchApplied = false

local function patchWavePhases()
    if _patchApplied then return end
    _patchApplied = true

    local Wave = require("wave")

    local origStartWave = Wave.startWave
    Wave.startWave = function(wtype)
        origStartWave(wtype)
        -- Begin a wave phase after the wave has been set up
        T.beginPhase("wave", {
            freshness = G.freshness,
            day = G.day,
            flyCount = G.fliesLeftToSpawn + #G.flies,
        })
    end

    local origShowUpgrades = Wave.showUpgrades
    Wave.showUpgrades = function()
        -- End the wave phase before transitioning
        T.endPhase("wave", {
            freshness = G.freshness,
            flyCount = #G.flies,
        })
        origShowUpgrades()
    end

    local origDoGameOver = Wave.doGameOver
    Wave.doGameOver = function()
        -- End wave phase if active when game over happens mid-wave
        if T.inPhase("wave") then
            T.endPhase("wave", {
                freshness = G.freshness,
                flyCount = #G.flies,
            })
        end
        origDoGameOver()
    end
end

-- Apply patches on first require
patchWavePhases()

------------------------------------------------------
-- EXPORT: wrap Bot to match game's calling conventions
------------------------------------------------------

-- The game calls Bot.update(dt, Wave, Telemetry, Input) but library takes just dt
local _libUpdate = Bot.update
Bot.update = function(dt, _wave, _telemetry, _input)
    -- Advance library telemetry time (game's own telemetry is separate)
    T.update(dt, G.state == "wave")
    _libUpdate(dt)
end

-- The game calls Bot.drawHUD() with no args; add game-specific info
local _libDrawHUD = Bot.drawHUD
Bot.drawHUD = function()
    _libDrawHUD(nil, nil, {
        "Day " .. G.day .. " | F:" .. math.floor(G.freshness),
    })
end

return Bot

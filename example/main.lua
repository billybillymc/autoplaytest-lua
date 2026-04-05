-- example/main.lua — Minimal LOVE2D game showing autoplaytest integration
--
-- A simple "click the circles" game with bot playtesting.
-- Run: love example
-- Run with bot: love example bot medium 10 4
--
-- This example uses LOVE2D, but the autoplaytest library itself is
-- engine-agnostic. See README.md for integration with other engines.

-- Add parent dir to path so require("autoplaytest") works
love.filesystem.setRequirePath(love.filesystem.getRequirePath() .. ";../?.lua;../?.lua;../?/init.lua")
package.path = package.path .. ";../?.lua;../?.lua;../?/init.lua"

local Autoplaytest = require("autoplaytest")
local Bot = Autoplaytest.Bot
local Telemetry = Autoplaytest.Telemetry

------------------------------------------------------
-- GAME STATE
------------------------------------------------------

local Game = {
    state = "play",   -- "play" or "gameover"
    score = 0,
    hp = 100,
    circles = {},
    spawnTimer = 0,
    W = 800,
    H = 600,
}

local function spawnCircle()
    table.insert(Game.circles, {
        x = math.random(50, Game.W - 50),
        y = math.random(50, Game.H - 50),
        radius = math.random(15, 35),
        life = 3.0,
    })
end

local function resetGame()
    Game.state = "play"
    Game.score = 0
    Game.hp = 100
    Game.circles = {}
    Game.spawnTimer = 0
end

local function handleClick(x, y)
    for i = #Game.circles, 1, -1 do
        local c = Game.circles[i]
        local dx, dy = c.x - x, c.y - y
        if math.sqrt(dx * dx + dy * dy) < c.radius then
            Telemetry.log("circle_hit", { x = x, y = y, radius = c.radius })
            table.remove(Game.circles, i)
            Game.score = Game.score + 1
            return
        end
    end
    Telemetry.log("miss", { x = x, y = y })
end

------------------------------------------------------
-- CONFIGURE BOT
------------------------------------------------------

Bot.screenW = Game.W
Bot.screenH = Game.H

Bot.getState = function()
    return Game.state
end

Bot.findTarget = function()
    -- Target the largest circle (easiest to hit)
    local best, bestR = nil, 0
    for _, c in ipairs(Game.circles) do
        if c.radius > bestR then
            best, bestR = c, c.radius
        end
    end
    if best then return best.x, best.y end
    return nil
end

Bot.onClick = function(x, y)
    handleClick(x, y)
end

Bot.onRunStart = function()
    resetGame()
    Telemetry.reset()
    Telemetry.playerTag = "bot_" .. Bot.skill
end

Bot.stateHandlers = {
    gameover = function(dt, bot)
        bot.handleRunEnd(dt)
    end,
}

-- Telemetry snapshot: capture game state periodically
Telemetry.snapshotFn = function()
    return { hp = Game.hp, score = Game.score, circles = #Game.circles }
end

Telemetry.summaryFn = function()
    return { finalScore = Game.score, finalHp = Game.hp }
end

------------------------------------------------------
-- LOVE CALLBACKS
------------------------------------------------------

function love.load()
    love.window.setTitle("Autoplaytest Example")
    love.window.setMode(Game.W, Game.H)
    resetGame()

    -- Check CLI for bot args
    local botArgs = Bot.parseCLI()
    if botArgs then
        Bot.speed = botArgs.speed
        Bot.autoQuit = true
        Bot.startBatch(botArgs.runs, botArgs.skill)
    end
end

function love.update(dt)
    local gameDt = dt * Bot.speed
    Telemetry.update(gameDt, Game.state == "play")
    Bot.update(gameDt)

    if Game.state ~= "play" then return end

    -- Spawn circles
    Game.spawnTimer = Game.spawnTimer + gameDt
    if Game.spawnTimer > 0.8 then
        Game.spawnTimer = 0
        spawnCircle()
    end

    -- Age circles, damage player when they expire
    for i = #Game.circles, 1, -1 do
        Game.circles[i].life = Game.circles[i].life - gameDt
        if Game.circles[i].life <= 0 then
            table.remove(Game.circles, i)
            Game.hp = Game.hp - 10
            Telemetry.log("circle_expired")
        end
    end

    if Game.hp <= 0 then
        Game.hp = 0
        Game.state = "gameover"
        Telemetry.log("game_over", { score = Game.score })
        Telemetry.endRun()
    end
end

function love.keypressed(key)
    if Bot.keypressed(key) then return end
    if key == "escape" then love.event.quit() end
    if Game.state == "gameover" and key == "return" then
        resetGame()
    end
end

function love.mousepressed(x, y, button)
    if Bot.enabled then return end
    if button == 1 and Game.state == "play" then
        handleClick(x, y)
    elseif button == 1 and Game.state == "gameover" then
        resetGame()
    end
end

function love.draw()
    love.graphics.clear(0.1, 0.1, 0.15)

    if Game.state == "play" then
        -- Draw circles
        for _, c in ipairs(Game.circles) do
            local alpha = math.min(1, c.life / 0.5)
            love.graphics.setColor(0.9, 0.3, 0.3, alpha)
            love.graphics.circle("fill", c.x, c.y, c.radius)
            love.graphics.setColor(1, 1, 1, alpha * 0.8)
            love.graphics.circle("line", c.x, c.y, c.radius)
        end

        -- HUD
        love.graphics.setColor(1, 1, 1)
        love.graphics.print("Score: " .. Game.score, 10, 10)
        love.graphics.print("HP: " .. Game.hp, 10, 30)
    else
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("GAME OVER\nScore: " .. Game.score .. "\n\nPress Enter or Click",
            0, Game.H / 2 - 40, Game.W, "center")
    end

    -- Bot cursor
    if Bot.enabled then
        love.graphics.setColor(0.3, 1, 0.3, 0.8)
        love.graphics.circle("line", Bot.cx, Bot.cy, 8)
        love.graphics.line(Bot.cx - 12, Bot.cy, Bot.cx + 12, Bot.cy)
        love.graphics.line(Bot.cx, Bot.cy - 12, Bot.cx, Bot.cy + 12)
    end

    -- Bot HUD overlay
    Bot.drawHUD(nil, nil, {
        "Score: " .. Game.score,
        "HP: " .. Game.hp,
    })
end

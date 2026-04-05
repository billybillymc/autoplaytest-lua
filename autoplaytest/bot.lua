-- autoplaytest/bot.lua — Generic AI player framework for automated playtesting
--
-- Engine-agnostic. Simulates a human player with configurable skill levels
-- (reaction time, accuracy, move speed, click rate). Drives a virtual cursor
-- and dispatches clicks into your game. You register per-state behavior
-- handlers and a target-finding function; the bot handles cursor movement,
-- jitter, and batch run management.
--
-- The only engine-specific bits are drawHUD() and quit behavior — override
-- Bot.drawFn and Bot.quitFn to wire into your engine.

local Bot = {}

Bot.enabled = false
Bot.speed = 1        -- game speed multiplier (1x, 2x, 4x, 8x, 16x)
Bot.skill = "medium"
Bot.runsTotal = 5
Bot.runsLeft = 0
Bot.runIndex = 0
Bot.restartTimer = 0
Bot.autoQuit = false -- quit application after all runs complete (for CI)

-- Virtual cursor position (design/world coordinates)
Bot.cx = 0
Bot.cy = 0

-- Internal targeting state
Bot.targetX = nil
Bot.targetY = nil
Bot.clickCooldown = 0
Bot.scanTimer = 0

-- Skill presets: reaction (seconds), accuracy (pixels of jitter),
-- moveSpeed (pixels/sec), clickRate (seconds between clicks)
Bot.skillParams = {
    low    = { reaction = 0.55, accuracy = 22, moveSpeed = 350, clickRate = 0.40 },
    medium = { reaction = 0.28, accuracy = 12, moveSpeed = 650, clickRate = 0.22 },
    high   = { reaction = 0.10, accuracy = 4,  moveSpeed = 1100, clickRate = 0.12 },
}

------------------------------------------------------
-- USER-SUPPLIED CALLBACKS
------------------------------------------------------

--- Called to find what the bot should click on during active gameplay.
-- Must return (x, y) in design/world coords, or nil if nothing to target.
Bot.findTarget = nil

--- Called when the bot clicks at (x, y) during active gameplay.
-- Wire this into your game's input handler.
Bot.onClick = nil

--- Table of state handlers: keys are game state names, values are functions.
-- Each function receives (dt, bot) and should drive the game forward.
-- The "play" state is handled internally (cursor movement + clicking).
Bot.stateHandlers = {}

--- Called to get the current game state name (string).
-- Must return one of the keys in stateHandlers, or "play" for active gameplay.
Bot.getState = nil

--- Called when a new run starts. Should reset the game to a playable state.
Bot.onRunStart = nil

--- Called when a run ends normally (not a restart). Optional.
Bot.onRunEnd = nil

--- Engine-specific: called to draw the HUD overlay.
-- Signature: function(bot, x, y, lines)
-- where lines is an array of strings to display.
-- Set this to your engine's text drawing implementation.
-- A LOVE2D default is provided if love.graphics is available.
Bot.drawFn = nil

--- Engine-specific: called to quit the application (for autoQuit/CI mode).
-- Default: calls love.event.quit() if available, otherwise os.exit(0).
Bot.quitFn = nil

--- Screen dimensions for cursor clamping (design coordinates).
Bot.screenW = 800
Bot.screenH = 600

------------------------------------------------------
-- MAIN UPDATE
------------------------------------------------------

function Bot.update(dt)
    if not Bot.enabled then return end

    local state = Bot.getState and Bot.getState() or "play"

    if state == "play" then
        Bot.playUpdate(dt)
    elseif Bot.stateHandlers[state] then
        Bot.stateHandlers[state](dt, Bot)
    end
end

------------------------------------------------------
-- ACTIVE GAMEPLAY (cursor movement + clicking)
------------------------------------------------------

function Bot.playUpdate(dt)
    local p = Bot.skillParams[Bot.skill]
    if not p then return end

    Bot.clickCooldown = Bot.clickCooldown - dt
    Bot.scanTimer = Bot.scanTimer - dt

    -- Periodically scan for a new target
    if Bot.scanTimer <= 0 or Bot.targetX == nil then
        Bot.scanTimer = p.reaction * (0.7 + math.random() * 0.6)
        if Bot.findTarget then
            Bot.targetX, Bot.targetY = Bot.findTarget()
        end
    end

    if not Bot.targetX then return end

    -- Move virtual cursor toward target
    local dx = Bot.targetX - Bot.cx
    local dy = Bot.targetY - Bot.cy
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist > 2 then
        local move = p.moveSpeed * dt
        if move > dist then move = dist end
        Bot.cx = Bot.cx + (dx / dist) * move
        Bot.cy = Bot.cy + (dy / dist) * move
    end

    -- Simulate imprecise mouse control (jitter)
    Bot.cx = Bot.cx + (math.random() - 0.5) * p.accuracy * 0.3
    Bot.cy = Bot.cy + (math.random() - 0.5) * p.accuracy * 0.3

    -- Clamp to screen bounds
    Bot.cx = math.max(10, math.min(Bot.screenW - 10, Bot.cx))
    Bot.cy = math.max(10, math.min(Bot.screenH - 10, Bot.cy))

    -- Click when close enough
    local clickDist = p.accuracy * 1.5
    if dist < clickDist and Bot.clickCooldown <= 0 then
        local clickX = Bot.cx + (math.random() - 0.5) * p.accuracy
        local clickY = Bot.cy + (math.random() - 0.5) * p.accuracy
        if Bot.onClick then
            Bot.onClick(clickX, clickY)
        end
        Bot.clickCooldown = p.clickRate * (0.8 + math.random() * 0.4)
        Bot.scanTimer = p.reaction * 0.3
    end
end

------------------------------------------------------
-- BATCH RUN MANAGEMENT
------------------------------------------------------

--- Start a batch of automated runs.
-- @param numRuns number  how many games to play
-- @param skill string|nil  "low", "medium", or "high" (default: current)
function Bot.startBatch(numRuns, skill)
    Bot.skill = skill or Bot.skill
    Bot.runsTotal = numRuns
    Bot.runsLeft = numRuns - 1
    Bot.runIndex = 1
    Bot.enabled = true
    Bot.restartTimer = 0
    Bot.beginRun()
end

--- Called internally to start a single run.
function Bot.beginRun()
    Bot.cx = Bot.screenW / 2
    Bot.cy = Bot.screenH / 2
    Bot.targetX = nil
    Bot.targetY = nil
    Bot.clickCooldown = 0
    Bot.scanTimer = 0
    if Bot.onRunStart then Bot.onRunStart() end
end

--- Call this from your game-over handler to advance to the next run.
-- @param dt number  delta time (used for a brief pause between runs)
function Bot.handleRunEnd(dt)
    Bot.restartTimer = Bot.restartTimer + dt
    if Bot.restartTimer < 0.3 then return end
    Bot.restartTimer = 0

    if Bot.onRunEnd then Bot.onRunEnd() end

    if Bot.runsLeft > 0 then
        Bot.runsLeft = Bot.runsLeft - 1
        Bot.runIndex = Bot.runIndex + 1
        Bot.beginRun()
    else
        Bot.enabled = false
        if Bot.autoQuit then
            Bot.quit()
        end
    end
end

------------------------------------------------------
-- ENGINE INTEGRATION (overridable)
------------------------------------------------------

--- Quit the application. Override Bot.quitFn for custom behavior.
function Bot.quit()
    if Bot.quitFn then
        Bot.quitFn()
    elseif love and love.event and love.event.quit then
        love.event.quit()
    else
        os.exit(0)
    end
end

--- Draw a small status overlay. Override Bot.drawFn for non-LOVE2D engines.
-- @param x number|nil  top-left X (default: screenW - 170)
-- @param y number|nil  top-left Y (default: 0)
-- @param extraLines table|nil  additional strings to display
function Bot.drawHUD(x, y, extraLines)
    if not Bot.enabled then return end

    x = x or (Bot.screenW - 170)
    y = y or 0

    local lines = {
        "BOT: " .. Bot.skill .. " | " .. Bot.speed .. "x",
        "Run " .. Bot.runIndex .. "/" .. Bot.runsTotal,
        string.format("Cursor: %d, %d", Bot.cx, Bot.cy),
    }
    if extraLines then
        for _, line in ipairs(extraLines) do
            lines[#lines + 1] = line
        end
    end

    if Bot.drawFn then
        Bot.drawFn(Bot, x, y, lines)
        return
    end

    -- Default LOVE2D implementation (no-op if love.graphics is unavailable)
    if not (love and love.graphics) then return end

    local lineH = 14
    local h = 8 + #lines * lineH

    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", x, y, 170, h, 0, 4)
    love.graphics.setColor(0.3, 1, 0.3)

    for i, line in ipairs(lines) do
        love.graphics.print(line, x + 6, y + 4 + (i - 1) * lineH)
    end
end

------------------------------------------------------
-- CLI ARGUMENT PARSING
------------------------------------------------------

--- Parse command-line arguments for bot configuration.
-- Usage: yourapp bot [skill] [runs] [speed]
-- e.g.:  love . bot medium 10 4
function Bot.parseCLI(args)
    args = args or arg or {}
    for i = 1, #args do
        if args[i] == "bot" then
            local skill = args[i + 1] or "medium"
            local runs = tonumber(args[i + 2]) or 5
            local speed = tonumber(args[i + 3]) or 4
            return { skill = skill, runs = runs, speed = speed }
        end
    end
    return nil
end

------------------------------------------------------
-- KEYBOARD CONTROLS
------------------------------------------------------

--- Provides default hotkeys. Call from your engine's key handler.
--   b     = toggle bot on/off
--   1/2/3 = set skill to low/medium/high
--   +/-   = double/halve speed
-- @param key string  the key name
-- @return boolean  true if the key was consumed
function Bot.keypressed(key)
    if key == "b" then
        if Bot.enabled then
            Bot.enabled = false
        else
            Bot.startBatch(5, Bot.skill)
        end
        return true
    end
    if key == "1" then Bot.skill = "low"; return true end
    if key == "2" then Bot.skill = "medium"; return true end
    if key == "3" then Bot.skill = "high"; return true end
    if key == "=" or key == "kp+" then
        Bot.speed = math.min(16, Bot.speed * 2); return true
    end
    if key == "-" or key == "kp-" then
        Bot.speed = math.max(1, Bot.speed / 2); return true
    end
    return false
end

return Bot

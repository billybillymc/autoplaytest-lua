-- autoplaytest/bot.lua — AI player framework for automated playtesting
--
-- Engine-agnostic. Simulates a human player with configurable skill levels.
-- Drives a virtual cursor with Fitts's law movement (acceleration,
-- deceleration, overshoot) and framerate-independent jitter.
--
-- Override Bot.drawFn and Bot.quitFn for your engine.

local Bot = {}

Bot.enabled = false
Bot.speed = 1        -- game speed multiplier (1x, 2x, 4x, 8x, 16x)
Bot.skill = "medium"
Bot.runsTotal = 5
Bot.runsLeft = 0
Bot.runIndex = 0
Bot.restartTimer = 0
Bot.autoQuit = false

-- Virtual cursor position (design/world coordinates)
Bot.cx = 0
Bot.cy = 0

-- Cursor velocity for Fitts's law movement
Bot.vx = 0
Bot.vy = 0

-- Internal targeting state
Bot.targetX = nil
Bot.targetY = nil
Bot.clickCooldown = 0
Bot.scanTimer = 0
Bot.jitterAccum = 0  -- accumulated time for framerate-independent jitter

-- Overshoot state
Bot.overshooting = false
Bot.overshootTimer = 0

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

--- Must return (x, y) of what to click, or nil.
Bot.findTarget = nil

--- Called when the bot clicks at (x, y).
Bot.onClick = nil

--- Table of state handlers: { stateName = function(dt, bot) }
--- "play" is handled internally (cursor movement + clicking).
Bot.stateHandlers = {}

--- Must return current game state name (string).
Bot.getState = nil

--- Called when a new run starts. Reset game here.
Bot.onRunStart = nil

--- Called when a run ends. Optional.
Bot.onRunEnd = nil

--- Engine-specific draw. Signature: function(bot, x, y, lines)
Bot.drawFn = nil

--- Engine-specific quit. Default: love.event.quit() or os.exit(0).
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
-- FITTS'S LAW CURSOR MOVEMENT
------------------------------------------------------
-- Humans move fast toward distant targets and slow down as they approach.
-- Modeled as: high acceleration at distance, strong deceleration near target,
-- with occasional overshoot on arrival.
--
-- The key insight: movement time = a + b * log2(distance/targetSize + 1)
-- We approximate this with a velocity model:
--   - Acceleration proportional to distance (far = fast start)
--   - Deceleration ramps up as cursor nears target
--   - Velocity is damped, not teleported, so there's natural overshoot

local function fittsMove(bot, dx, dy, dist, p, dt)
    local maxSpeed = p.moveSpeed

    -- Acceleration factor: stronger when far, weaker when close
    -- This creates the characteristic fast-start, slow-finish curve
    local accelZone = 200  -- pixels: distance at which we're at full accel
    local distFactor = math.min(1.0, dist / accelZone)

    -- Target velocity: high when far, low when close
    local targetSpeed = maxSpeed * distFactor

    -- Direction toward target
    local nx, ny = 0, 0
    if dist > 0.1 then
        nx, ny = dx / dist, dy / dist
    end

    -- Target velocity vector
    local tvx = nx * targetSpeed
    local tvy = ny * targetSpeed

    -- Smoothly blend current velocity toward target velocity
    -- Higher smoothing = more sluggish (lower skill = more sluggish)
    local responsiveness = 8 + (1 - p.reaction) * 12  -- faster reaction = snappier
    local blend = 1 - math.exp(-responsiveness * dt)
    bot.vx = bot.vx + (tvx - bot.vx) * blend
    bot.vy = bot.vy + (tvy - bot.vy) * blend

    -- Apply velocity
    bot.cx = bot.cx + bot.vx * dt
    bot.cy = bot.cy + bot.vy * dt

    -- Overshoot: when arriving at target, sometimes overshoot and correct
    if dist < p.accuracy * 2 and not bot.overshooting then
        local speed = math.sqrt(bot.vx * bot.vx + bot.vy * bot.vy)
        -- Overshoot chance scales with speed and inverse skill
        if speed > maxSpeed * 0.3 and math.random() < p.accuracy / 40 then
            bot.overshooting = true
            bot.overshootTimer = 0.05 + math.random() * 0.08
            -- Add momentum burst in current direction
            local overshootMag = p.accuracy * (0.5 + math.random() * 0.5)
            bot.vx = bot.vx + nx * overshootMag / dt * 0.02
            bot.vy = bot.vy + ny * overshootMag / dt * 0.02
        end
    end

    if bot.overshooting then
        bot.overshootTimer = bot.overshootTimer - dt
        if bot.overshootTimer <= 0 then
            bot.overshooting = false
        end
    end
end

------------------------------------------------------
-- FRAMERATE-INDEPENDENT JITTER
------------------------------------------------------
-- Instead of applying jitter every frame, we accumulate time and apply
-- jitter at a fixed rate (~30 times/sec). This ensures consistent
-- behavior regardless of framerate.

local JITTER_INTERVAL = 1 / 30  -- apply jitter 30 times per second

local function applyJitter(bot, p, dt)
    bot.jitterAccum = bot.jitterAccum + dt
    while bot.jitterAccum >= JITTER_INTERVAL do
        bot.jitterAccum = bot.jitterAccum - JITTER_INTERVAL
        bot.cx = bot.cx + (math.random() - 0.5) * p.accuracy * 0.3
        bot.cy = bot.cy + (math.random() - 0.5) * p.accuracy * 0.3
    end
end

------------------------------------------------------
-- ACTIVE GAMEPLAY
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

    if not Bot.targetX then
        -- Idle: gradually decelerate
        Bot.vx = Bot.vx * (1 - 3 * dt)
        Bot.vy = Bot.vy * (1 - 3 * dt)
        Bot.cx = Bot.cx + Bot.vx * dt
        Bot.cy = Bot.cy + Bot.vy * dt
        applyJitter(Bot, p, dt)
        Bot.clampCursor()
        return
    end

    -- Move toward target using Fitts's law
    local dx = Bot.targetX - Bot.cx
    local dy = Bot.targetY - Bot.cy
    local dist = math.sqrt(dx * dx + dy * dy)

    fittsMove(Bot, dx, dy, dist, p, dt)
    applyJitter(Bot, p, dt)
    Bot.clampCursor()

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

function Bot.clampCursor()
    Bot.cx = math.max(10, math.min(Bot.screenW - 10, Bot.cx))
    Bot.cy = math.max(10, math.min(Bot.screenH - 10, Bot.cy))
end

------------------------------------------------------
-- BATCH RUN MANAGEMENT
------------------------------------------------------

function Bot.startBatch(numRuns, skill)
    Bot.skill = skill or Bot.skill
    Bot.runsTotal = numRuns
    Bot.runsLeft = numRuns - 1
    Bot.runIndex = 1
    Bot.enabled = true
    Bot.restartTimer = 0
    Bot.beginRun()
end

function Bot.beginRun()
    Bot.cx = Bot.screenW / 2
    Bot.cy = Bot.screenH / 2
    Bot.vx = 0
    Bot.vy = 0
    Bot.targetX = nil
    Bot.targetY = nil
    Bot.clickCooldown = 0
    Bot.scanTimer = 0
    Bot.jitterAccum = 0
    Bot.overshooting = false
    Bot.overshootTimer = 0
    if Bot.onRunStart then Bot.onRunStart() end
end

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
        if Bot.autoQuit then Bot.quit() end
    end
end

------------------------------------------------------
-- ENGINE INTEGRATION (overridable)
------------------------------------------------------

function Bot.quit()
    if Bot.quitFn then
        Bot.quitFn()
    elseif love and love.event and love.event.quit then
        love.event.quit()
    else
        os.exit(0)
    end
end

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

    -- Default LOVE2D fallback
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

# autoplaytest-lua

Automated playtesting framework for Lua games. Simulates human players at configurable skill levels, collects telemetry, computes batch statistics, and runs balance assertions -- useful for difficulty tuning, regression detection, and CI smoke tests.

Works with any Lua game engine (LOVE2D, Defold, Solar2D, Playdate, plain Lua). Engine-specific bits (drawing, file I/O, quit) are behind overridable callbacks with sensible defaults.

## Features

- **Fitts's law cursor movement** -- acceleration/deceleration curves with occasional overshoot, not constant-speed linear movement
- **Framerate-independent jitter** -- consistent mouse imprecision regardless of FPS (fixed 30Hz jitter tick)
- **Skill presets** (low / medium / high) controlling reaction time, accuracy, movement speed, and click rate
- **Phase tracking** -- generic begin/end phase pairs with automatic duration and numeric delta computation
- **Batch statistics** -- mean, stddev, min, max across all runs for every numeric field
- **Balance assertions** -- define pass/fail criteria per run, get exit code 1 on failure for CI
- **Batch runs** -- queue N automated playthroughs back-to-back
- **Speed multiplier** -- run games at 2x, 4x, 8x, 16x
- **CLI support** -- `yourapp bot medium 10 4` for headless CI
- **Engine-agnostic** -- zero hard dependencies; LOVE2D fallbacks provided

## Installation

Copy the `autoplaytest/` directory into your project:

```
your-game/
  autoplaytest/
    init.lua
    bot.lua
    telemetry.lua
  main.lua
  ...
```

Then require it:

```lua
local APT = require("autoplaytest")
local Bot = APT.Bot
local T = APT.Telemetry
```

## Quick Start

### 1. Configure the bot

```lua
Bot.screenW = 800
Bot.screenH = 600

-- Return current game state. "play" triggers cursor movement + clicking.
Bot.getState = function()
    if Game.state == "combat" then return "play"
    else return Game.state end
end

-- Return (x, y) of what to click, or nil.
Bot.findTarget = function()
    local enemy = findClosestEnemy()
    if enemy then return enemy.x, enemy.y end
    return nil
end

-- Dispatch a click into your game.
Bot.onClick = function(x, y)
    Game.handleClick(x, y)
end

-- Reset the game for a new run.
Bot.onRunStart = function()
    Game.reset()
    T.reset()
    T.playerTag = "bot_" .. Bot.skill
end
```

### 2. Handle non-gameplay states

```lua
Bot.stateHandlers = {
    upgrade = function(dt, bot)
        local choices = Game.getUpgradeChoices()
        choices[math.random(#choices)].apply()
        Game.nextState()
    end,
    gameover = function(dt, bot)
        bot.handleRunEnd(dt)
    end,
}
```

### 3. Wire into your update loop

```lua
function love.update(dt)
    local gameDt = dt * Bot.speed
    T.update(gameDt, Game.state == "combat")
    Bot.update(gameDt)
    -- ... your game logic ...
end

function love.keypressed(key)
    if Bot.keypressed(key) then return end
    -- ... your input ...
end

function love.mousepressed(x, y, button)
    if Bot.enabled then return end
    -- ... your click handling ...
end

function love.draw()
    -- ... your game drawing ...
    Bot.drawHUD()
end
```

### 4. Set up telemetry

```lua
-- Log events from your game code
T.log("enemy_killed", { x = e.x, y = e.y, type = e.type })

-- Track phases (e.g., combat waves, levels)
T.beginPhase("wave", { health = player.hp, enemies = 12 })
-- ... gameplay ...
T.endPhase("wave", { health = player.hp, enemies = 0 })
-- Automatically computes: duration, health_delta, enemies_delta

-- Periodic snapshots
T.snapshotFn = function()
    return { health = player.hp, enemies = #enemies, score = score }
end

-- Per-run summary
T.summaryFn = function()
    return { finalScore = score, finalLevel = level }
end

-- Call at game over
T.endRun()
```

### 5. Add balance assertions

```lua
T.addAssertion("medium bot survives past level 3", function(run)
    return (run.finalLevel or 0) >= 3
end)

T.addAssertion("score above 50 for most runs", function(run)
    return (run.finalScore or 0) >= 50
end, "majority")  -- passes if >50% of runs pass
```

After all runs complete:

```lua
print(T.formatBatchStats())
print(T.formatAssertions())
local check = T.checkAssertions()
if not check.passed then os.exit(1) end
```

## Cursor Movement: Fitts's Law

The bot doesn't move at constant speed. It models human mouse behavior:

- **Fast start**: high acceleration when cursor is far from target
- **Slow approach**: deceleration as cursor nears target (distance-proportional velocity)
- **Overshoot**: occasional momentum-based overshoot on arrival, then correction
- **Jitter**: framerate-independent random perturbation at fixed 30Hz tick rate
- **Idle drift**: gradual deceleration when no target is available

The responsiveness scales with the skill preset's reaction time -- high-skill bots have snappier cursor response.

## Engine Integration

Three callbacks handle all engine-specific behavior:

| Callback | Purpose | Default |
|---|---|---|
| `Bot.drawFn` | Draw the HUD overlay | `love.graphics` if available, else no-op |
| `Bot.quitFn` | Quit the application | `love.event.quit()` if available, else `os.exit(0)` |
| `T.writeFn` | Write results to disk | `love.filesystem.write` if available, else `io.open` |

### Defold example

```lua
Bot.drawFn = function(bot, x, y, lines)
    for i, line in ipairs(lines) do
        msg.post("@render:", "draw_text", {
            text = line, position = vmath.vector3(x, y + (i-1) * 16, 0)
        })
    end
end
Bot.quitFn = function() sys.exit(0) end
T.writeFn = function(filename, contents)
    sys.save(sys.get_save_file("myapp", filename), { data = contents })
end
```

### Headless CI (no graphics)

```lua
Bot.drawFn = function() end
-- quitFn and writeFn default to os.exit / io.open when love is unavailable
```

## CLI Usage

```bash
love . bot medium 10 4    # 10 runs, medium skill, 4x speed
lua main.lua bot high 5 8 # plain Lua, 5 runs, high skill, 8x speed
```

```lua
local botArgs = Bot.parseCLI()
if botArgs then
    Bot.speed = botArgs.speed
    Bot.autoQuit = true
    Bot.startBatch(botArgs.runs, botArgs.skill)
end
```

## Runtime Controls

| Key | Action |
|-----|--------|
| `B` | Toggle bot on/off |
| `1` / `2` / `3` | Set skill to low / medium / high |
| `+` / `-` | Double / halve game speed |

## Skill Presets

| Preset | Reaction | Accuracy | Move Speed | Click Rate |
|--------|----------|----------|------------|------------|
| low    | 550ms    | 22px     | 350 px/s   | 400ms      |
| medium | 280ms    | 12px     | 650 px/s   | 220ms      |
| high   | 100ms    | 4px      | 1100 px/s  | 120ms      |

Custom presets:

```lua
Bot.skillParams.superhuman = {
    reaction = 0.05, accuracy = 2, moveSpeed = 2000, clickRate = 0.08
}
```

## Telemetry Output

### Per-run results (Lua table)

```lua
return {
  { -- Run 1
    player = "bot_medium",
    duration = 142.3,
    timestamp = 1775619878,
    totalEvents = 291,
    finalScore = 123,
    eventCounts = {
      snapshot = 220, phase_start = 15, phase_end = 15,
      upgrade = 14, path = 14, game_over = 1,
    },
    phases = {
      wave = {
        { duration=13.5, flyCount_delta=-4, freshness_delta=-5.5 },
        { duration=5.9, flyCount_delta=-5, freshness_delta=3.9 },
        -- ...
      },
    },
  },
}
```

### Batch statistics (printed)

```
Batch Statistics (3 runs):
  duration              mean=142.22  stddev=16.46  min=128.44  max=165.36
  finalDay              mean=16.00  stddev=0.00  min=16.00  max=16.00
  finalScore            mean=123.33  stddev=1.89  min=122.00  max=126.00
```

### Balance assertions (printed)

```
Balance Assertions:
  [PASS] bot_medium survives past day 3 -- 3/3 passed
  [PASS] bot_high survives past day 8 -- 3/3 passed
All assertions passed.
```

## API Reference

### Bot

| Field / Method | Description |
|---|---|
| `Bot.enabled` | `boolean` -- is the bot active |
| `Bot.speed` | `number` -- game speed multiplier |
| `Bot.skill` | `string` -- current skill preset name |
| `Bot.cx, Bot.cy` | `number` -- virtual cursor position |
| `Bot.vx, Bot.vy` | `number` -- cursor velocity (Fitts's law) |
| `Bot.screenW, Bot.screenH` | `number` -- design coordinate bounds |
| `Bot.findTarget` | `function() -> x, y or nil` |
| `Bot.onClick` | `function(x, y)` |
| `Bot.getState` | `function() -> string` |
| `Bot.stateHandlers` | `table<string, function(dt, bot)>` |
| `Bot.onRunStart` | `function()` |
| `Bot.onRunEnd` | `function()` |
| `Bot.drawFn` | `function(bot, x, y, lines)` |
| `Bot.quitFn` | `function()` |
| `Bot.skillParams` | `table` -- skill preset definitions |
| `Bot.update(dt)` | Call from your update loop |
| `Bot.keypressed(key) -> bool` | Call from key handler |
| `Bot.drawHUD(x, y, extraLines)` | Draw status overlay |
| `Bot.startBatch(runs, skill)` | Start N automated runs |
| `Bot.handleRunEnd(dt)` | Advance to next run |
| `Bot.parseCLI(args)` | Parse CLI arguments |
| `Bot.quit()` | Quit application |

### Telemetry

| Field / Method | Description |
|---|---|
| `T.playerTag` | `string` -- player identifier |
| `T.outputFile` | `string` -- results filename (default: "telemetry.lua") |
| `T.snapshotInterval` | `number` -- seconds between snapshots (default: 0.5) |
| `T.snapshotFn` | `function() -> table` |
| `T.summaryFn` | `function() -> table` |
| `T.writeFn` | `function(filename, contents)` |
| `T.reset()` | Clear events for a new run |
| `T.log(type, data)` | Log a named event |
| `T.update(dt, isPlaying)` | Advance time + periodic snapshots |
| `T.beginPhase(name, startData)` | Begin a named phase |
| `T.endPhase(name, endData)` | End phase, compute duration + deltas |
| `T.inPhase(name) -> bool` | Check if phase is active |
| `T.query(type, filterFn) -> events` | Find events by type |
| `T.count(type, filterFn) -> number` | Count events by type |
| `T.endRun()` | Compute summary and save |
| `T.batchStats() -> table` | Aggregate stats across runs |
| `T.formatBatchStats() -> string` | Pretty-print batch stats |
| `T.addAssertion(name, fn, mode)` | Register a balance assertion |
| `T.checkAssertions() -> table` | Run all assertions |
| `T.formatAssertions() -> string` | Pretty-print assertion results |
| `T.runResults` | `table` -- all run summaries |

## Example

See `example/bot_apt.lua` for a real-world integration with a LOVE2D roguelike game, demonstrating:
- Targeting (closest enemy to cursor)
- Strategy (heal when low, fight otherwise)
- Phase tracking (per-wave stats)
- Balance assertions
- Batch statistics output

## License

MIT

# autoplaytest-lua

Automated playtesting framework for Lua games.

Drop in a simulated AI player that plays your game at configurable skill levels, collects telemetry, and exports per-run summaries — useful for balance testing, regression detection, and CI smoke tests.

Works with any Lua game engine (LOVE2D, Defold, Solar2D, Playdate, plain Lua, etc.). Engine-specific bits (drawing, file I/O, quit) are behind overridable callbacks with sensible defaults.

## Features

- **Bot framework** with configurable skill presets (low / medium / high) controlling reaction time, cursor accuracy, movement speed, and click rate
- **Virtual cursor** with human-like jitter and movement
- **Batch runs** — queue N automated playthroughs back-to-back
- **Speed multiplier** — run games at 2x, 4x, 8x, 16x for fast iteration
- **Telemetry** — structured event logging, periodic state snapshots, per-run summaries exported as Lua tables
- **CLI support** — start bot runs from the command line for CI integration
- **HUD overlay** — pluggable drawing callback for bot status display
- **Keyboard controls** — toggle bot, switch skill levels, adjust speed at runtime
- **Engine-agnostic** — zero hard dependencies on any engine; LOVE2D fallbacks provided out of the box

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
local Autoplaytest = require("autoplaytest")
local Bot = Autoplaytest.Bot
local Telemetry = Autoplaytest.Telemetry
```

## Quick Start

### 1. Configure the bot

```lua
-- Tell the bot about your screen size (design coordinates)
Bot.screenW = 800
Bot.screenH = 600

-- How to read current game state
Bot.getState = function()
    return Game.state  -- return "play" for active gameplay, or your state name
end

-- How to find what to click during active play
Bot.findTarget = function()
    local enemy = findClosestEnemy()
    if enemy then return enemy.x, enemy.y end
    return nil
end

-- How to perform a click
Bot.onClick = function(x, y)
    Game.handleClick(x, y)
end

-- How to reset for a new run
Bot.onRunStart = function()
    Game.reset()
    Telemetry.reset()
    Telemetry.playerTag = "bot_" .. Bot.skill
end
```

### 2. Handle non-gameplay states

```lua
Bot.stateHandlers = {
    -- Bot picks a random upgrade when in upgrade screen
    upgrade = function(dt, bot)
        local choices = Game.getUpgradeChoices()
        choices[math.random(#choices)].apply()
        Game.nextState()
    end,
    -- Bot advances to next run on game over
    gameover = function(dt, bot)
        bot.handleRunEnd(dt)
    end,
}
```

### 3. Wire into your update loop

```lua
-- In your update function (e.g. love.update, or your engine's tick):
function update(dt)
    local gameDt = dt * Bot.speed
    Telemetry.update(gameDt, Game.state == "play")
    Bot.update(gameDt)
    -- ... your game update logic ...
end

-- In your key handler:
function onKeyPressed(key)
    if Bot.keypressed(key) then return end
    -- ... your input handling ...
end

-- In your click/touch handler:
function onMousePressed(x, y, button)
    if Bot.enabled then return end  -- ignore human input during bot play
    -- ... your click handling ...
end

-- In your draw function:
function draw()
    -- ... your game drawing ...
    Bot.drawHUD()  -- show bot status overlay (delegates to drawFn callback)
end
```

### 4. Set up telemetry

```lua
-- Log events from your game code
Telemetry.log("enemy_killed", { x = e.x, y = e.y, type = e.type })
Telemetry.log("upgrade_picked", { name = upgrade.name })

-- Periodic snapshots capture game state automatically
Telemetry.snapshotFn = function()
    return { health = player.hp, enemies = #enemies, score = score }
end

-- Summary data included in per-run results
Telemetry.summaryFn = function()
    return { finalScore = score, finalLevel = level, finalHealth = player.hp }
end

-- Call at game over
Telemetry.endRun()
```

## Engine Integration

The library has **zero hard dependencies**. Three callbacks handle all engine-specific behavior:

| Callback | Purpose | Default |
|---|---|---|
| `Bot.drawFn` | Draw the HUD overlay | Uses `love.graphics` if available, otherwise no-op |
| `Bot.quitFn` | Quit the application (CI mode) | Uses `love.event.quit()` if available, otherwise `os.exit(0)` |
| `Telemetry.writeFn` | Write results to disk | Uses `love.filesystem.write` if available, otherwise `io.open` |

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

Telemetry.writeFn = function(filename, contents)
    sys.save(sys.get_save_file("myapp", filename), { data = contents })
end
```

### Plain Lua (headless CI)

```lua
-- No drawing needed, file I/O works via io.open by default
Bot.drawFn = function() end  -- no-op
-- Bot.quitFn defaults to os.exit(0) when love is unavailable
```

## CLI Usage

Start bot runs from the command line:

```bash
# LOVE2D
love . bot medium 10 4

# Plain Lua (if your game supports headless mode)
lua main.lua bot high 5 8
```

Parse CLI args at startup:

```lua
local botArgs = Bot.parseCLI()
if botArgs then
    Bot.speed = botArgs.speed
    Bot.autoQuit = true  -- exit when done
    Bot.startBatch(botArgs.runs, botArgs.skill)
end
```

## Runtime Controls

| Key | Action |
|-----|--------|
| `B` | Toggle bot on/off (starts 5 runs) |
| `1` | Set skill to low |
| `2` | Set skill to medium |
| `3` | Set skill to high |
| `+` | Double game speed |
| `-` | Halve game speed |

## Skill Presets

| Preset | Reaction | Accuracy | Move Speed | Click Rate |
|--------|----------|----------|------------|------------|
| low    | 550ms    | 22px     | 350 px/s   | 400ms      |
| medium | 280ms    | 12px     | 650 px/s   | 220ms      |
| high   | 100ms    | 4px      | 1100 px/s  | 120ms      |

Add custom presets:

```lua
Bot.skillParams.superhuman = {
    reaction = 0.05, accuracy = 2, moveSpeed = 2000, clickRate = 0.08
}
```

## Telemetry Output

Results are written to `telemetry.lua` (configurable via `T.outputFile`). Each run produces a summary table:

```lua
return {
  { -- Run 1
    player = "bot_medium",
    duration = 45.2,
    totalEvents = 312,
    finalScore = 47,
    eventCounts = {
      enemy_killed = 47,
      miss = 23,
      snapshot = 90,
      game_over = 1,
    },
  },
  -- ...
}
```

## Example

See `example/main.lua` for a complete LOVE2D integration with a minimal "click the circles" game.

```bash
cd autoplaytest-lua
love example              # play manually
love example bot high 5 8 # watch 5 bot runs at 8x speed
```

## API Reference

### Bot

| Field / Method | Description |
|---|---|
| `Bot.enabled` | `boolean` — is the bot currently active |
| `Bot.speed` | `number` — game speed multiplier |
| `Bot.skill` | `string` — current skill preset name |
| `Bot.cx, Bot.cy` | `number` — virtual cursor position |
| `Bot.screenW, Bot.screenH` | `number` — design coordinate bounds |
| `Bot.findTarget` | `function() -> x, y or nil` — targeting callback |
| `Bot.onClick` | `function(x, y)` — click dispatch callback |
| `Bot.getState` | `function() -> string` — game state callback |
| `Bot.stateHandlers` | `table<string, function(dt, bot)>` — per-state behaviors |
| `Bot.onRunStart` | `function()` — new run callback |
| `Bot.onRunEnd` | `function()` — run complete callback |
| `Bot.drawFn` | `function(bot, x, y, lines)` — engine-specific HUD drawing |
| `Bot.quitFn` | `function()` — engine-specific quit |
| `Bot.skillParams` | `table` — skill preset definitions |
| `Bot.update(dt)` | Call from your update loop |
| `Bot.keypressed(key)` | Call from your key handler, returns `true` if consumed |
| `Bot.drawHUD(x, y, extraLines)` | Draw status overlay (delegates to drawFn) |
| `Bot.startBatch(runs, skill)` | Start N automated runs |
| `Bot.handleRunEnd(dt)` | Advance to next run (call from gameover handler) |
| `Bot.parseCLI(args)` | Parse command-line bot arguments |

### Telemetry

| Field / Method | Description |
|---|---|
| `Telemetry.playerTag` | `string` — identifies the player ("human", "bot_medium") |
| `Telemetry.outputFile` | `string` — filename for results (default: "telemetry.lua") |
| `Telemetry.snapshotInterval` | `number` — seconds between snapshots (default: 0.5) |
| `Telemetry.snapshotFn` | `function() -> table` — snapshot data callback |
| `Telemetry.summaryFn` | `function() -> table` — summary data callback |
| `Telemetry.writeFn` | `function(filename, contents)` — engine-specific file write |
| `Telemetry.reset()` | Clear events for a new run |
| `Telemetry.log(type, data)` | Log a named event |
| `Telemetry.update(dt, isPlaying)` | Call from your update loop for periodic snapshots |
| `Telemetry.endRun()` | Compute summary and save results |
| `Telemetry.runResults` | `table` — all accumulated run summaries |

## License

MIT

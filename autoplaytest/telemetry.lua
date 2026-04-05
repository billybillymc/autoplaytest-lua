-- autoplaytest/telemetry.lua — Game event logging, snapshots, and run summary export
--
-- Engine-agnostic telemetry system for automated playtesting.
-- Hook into your game events via T.log() and the provided callbacks,
-- then call T.endRun() at game over to accumulate per-run summaries.
--
-- File output uses T.writeFn — override it for your engine/environment.
-- A default using love.filesystem is provided if available, with an
-- io.open fallback for plain Lua.

local T = {}

T.events = {}
T.gameTime = 0
T.snapshotInterval = 0.5  -- seconds between periodic snapshots
T.snapshotTimer = 0
T.runResults = {}
T.playerTag = "human"     -- "human", "bot_low", "bot_medium", etc.
T.outputFile = "telemetry.lua"

-- User-supplied function: returns a table of game state for snapshots.
-- e.g. function() return { health = player.hp, enemies = #enemies } end
T.snapshotFn = nil

-- User-supplied function: returns a table of state to include in the summary.
-- Called at endRun. e.g. function() return { finalScore = score, level = level } end
T.summaryFn = nil

--- Engine-specific: called to write results to disk.
-- Signature: function(filename, contents)
-- Default: uses love.filesystem.write if available, otherwise io.open.
T.writeFn = nil

------------------------------------------------------
-- CORE API
------------------------------------------------------

function T.reset()
    T.events = {}
    T.gameTime = 0
    T.snapshotTimer = 0
end

--- Log a named event with optional data.
-- @param eventType string  e.g. "wave_start", "enemy_killed", "upgrade_picked"
-- @param data table|nil    arbitrary key/value pairs merged into the event
function T.log(eventType, data)
    local event = { t = T.gameTime, type = eventType }
    if data then
        for k, v in pairs(data) do event[k] = v end
    end
    T.events[#T.events + 1] = event
end

------------------------------------------------------
-- PERIODIC SNAPSHOTS
------------------------------------------------------

--- Call from your update loop. Logs periodic snapshots during play.
-- @param dt number  delta time (already scaled by bot speed if applicable)
-- @param isPlaying boolean|nil  only snapshot when true (default: true)
function T.update(dt, isPlaying)
    T.gameTime = T.gameTime + dt
    if isPlaying == false then return end
    T.snapshotTimer = T.snapshotTimer + dt
    if T.snapshotTimer >= T.snapshotInterval then
        T.snapshotTimer = 0
        local snap = {}
        if T.snapshotFn then
            local data = T.snapshotFn()
            if data then
                for k, v in pairs(data) do snap[k] = v end
            end
        end
        T.log("snapshot", snap)
    end
end

------------------------------------------------------
-- RUN LIFECYCLE
------------------------------------------------------

--- Call when a playtest run ends (game over, victory, etc.).
-- Computes a summary from logged events + summaryFn, appends to runResults, and saves.
function T.endRun()
    local summary = T.computeSummary()
    T.runResults[#T.runResults + 1] = summary
    T.saveResults()
end

--- Compute a summary of the current run's events.
-- Counts events by type and merges user-supplied summary data.
function T.computeSummary()
    local counts = {}
    for _, e in ipairs(T.events) do
        counts[e.type] = (counts[e.type] or 0) + 1
    end

    local summary = {
        player = T.playerTag,
        duration = T.gameTime,
        eventCounts = counts,
        totalEvents = #T.events,
    }

    -- Merge user-supplied summary fields
    if T.summaryFn then
        local extra = T.summaryFn()
        if extra then
            for k, v in pairs(extra) do summary[k] = v end
        end
    end

    return summary
end

------------------------------------------------------
-- EXPORT
------------------------------------------------------

--- Write a string to a file. Override T.writeFn for custom behavior.
function T.writeFile(filename, contents)
    if T.writeFn then
        T.writeFn(filename, contents)
        return
    end

    -- Default: try love.filesystem first, fall back to io.open
    if love and love.filesystem and love.filesystem.write then
        love.filesystem.write(filename, contents)
    else
        local f = io.open(filename, "w")
        if f then
            f:write(contents)
            f:close()
        end
    end
end

--- Serialize and write all run results.
function T.saveResults()
    local lines = {}
    local function w(s) lines[#lines + 1] = s end

    w("return {")
    for i, run in ipairs(T.runResults) do
        w("  { -- Run " .. i)
        for k, v in pairs(run) do
            if k ~= "eventCounts" then
                w("    " .. k .. " = " .. T.serialize(v) .. ",")
            end
        end
        if run.eventCounts then
            w("    eventCounts = {")
            for etype, count in pairs(run.eventCounts) do
                w("      " .. etype .. " = " .. count .. ",")
            end
            w("    },")
        end
        w("  },")
    end
    w("}")

    T.writeFile(T.outputFile, table.concat(lines, "\n") .. "\n")
end

--- Basic value serializer for Lua literals.
function T.serialize(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = {}
        -- Array part
        for i, item in ipairs(v) do
            parts[#parts + 1] = T.serialize(item)
        end
        -- Hash part (skip integer keys already covered)
        local maxn = #v
        for k, val in pairs(v) do
            if type(k) ~= "number" or k < 1 or k > maxn or k ~= math.floor(k) then
                parts[#parts + 1] = "[" .. T.serialize(k) .. "] = " .. T.serialize(val)
            end
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    else
        return '"' .. tostring(v) .. '"'
    end
end

return T

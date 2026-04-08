-- autoplaytest/telemetry.lua — Event logging, phase tracking, batch stats, assertions
--
-- Engine-agnostic. Override T.writeFn for your engine.

local T = {}

T.events = {}
T.gameTime = 0
T.snapshotInterval = 0.5
T.snapshotTimer = 0
T.runResults = {}
T.playerTag = "human"
T.outputFile = "telemetry.lua"

-- Active phases: { phaseName = { startTime, startData } }
T.phases = {}

-- User callbacks
T.snapshotFn = nil   -- function() -> table of state to snapshot
T.summaryFn = nil    -- function() -> table of extra fields for run summary
T.writeFn = nil      -- function(filename, contents)

-- Assertions: { { name, fn, mode } }
-- fn receives (runSummary) and returns true/false
-- mode: "every" (must pass every run) or "majority" (>50% of runs)
T.assertions = {}

------------------------------------------------------
-- CORE API
------------------------------------------------------

function T.reset()
    T.events = {}
    T.gameTime = 0
    T.snapshotTimer = 0
    T.phases = {}
end

--- Log a named event with optional data.
function T.log(eventType, data)
    local event = { t = T.gameTime, type = eventType }
    if data then
        for k, v in pairs(data) do event[k] = v end
    end
    T.events[#T.events + 1] = event
end

------------------------------------------------------
-- PHASE TRACKING
------------------------------------------------------
-- Generic begin/end phase pairs. Automatically computes duration
-- and diffs any numeric fields between start and end snapshots.
--
-- Usage:
--   T.beginPhase("wave", { day = 5, freshness = 80, flies = 12 })
--   ... gameplay ...
--   T.endPhase("wave", { freshness = 55, flies = 0 })
--   -- logged event includes: duration, freshness_delta = -25, flies_delta = -12

--- Begin a named phase. startData is an optional table of numeric state.
function T.beginPhase(name, startData)
    T.phases[name] = {
        startTime = T.gameTime,
        startData = startData or {},
    }
    local logData = { phase = name }
    if startData then
        for k, v in pairs(startData) do logData[k] = v end
    end
    T.log("phase_start", logData)
end

--- End a named phase. endData is an optional table of numeric state.
--- Automatically computes duration and deltas for matching numeric keys.
function T.endPhase(name, endData)
    local phase = T.phases[name]
    if not phase then return end

    local duration = T.gameTime - phase.startTime
    local logData = {
        phase = name,
        duration = duration,
    }

    endData = endData or {}
    -- Copy end data
    for k, v in pairs(endData) do
        logData[k] = v
    end

    -- Compute deltas for numeric fields present in both start and end
    for k, startVal in pairs(phase.startData) do
        if type(startVal) == "number" and type(endData[k]) == "number" then
            logData[k .. "_delta"] = endData[k] - startVal
        end
    end

    T.log("phase_end", logData)
    T.phases[name] = nil
end

--- Check if a phase is currently active.
function T.inPhase(name)
    return T.phases[name] ~= nil
end

------------------------------------------------------
-- PERIODIC SNAPSHOTS
------------------------------------------------------

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
-- EVENT QUERIES
------------------------------------------------------

--- Return all events matching a type and optional filter function.
function T.query(eventType, filterFn)
    local results = {}
    for _, e in ipairs(T.events) do
        if e.type == eventType then
            if not filterFn or filterFn(e) then
                results[#results + 1] = e
            end
        end
    end
    return results
end

--- Count events matching a type and optional filter.
function T.count(eventType, filterFn)
    local n = 0
    for _, e in ipairs(T.events) do
        if e.type == eventType then
            if not filterFn or filterFn(e) then
                n = n + 1
            end
        end
    end
    return n
end

------------------------------------------------------
-- RUN LIFECYCLE
------------------------------------------------------

function T.endRun()
    local summary = T.computeSummary()
    T.runResults[#T.runResults + 1] = summary
    T.saveResults()
end

function T.computeSummary()
    local counts = {}
    for _, e in ipairs(T.events) do
        counts[e.type] = (counts[e.type] or 0) + 1
    end

    -- Gather phase summaries
    local phaseSummaries = {}
    local currentPhases = {}
    for _, e in ipairs(T.events) do
        if e.type == "phase_start" then
            currentPhases[e.phase] = e
        elseif e.type == "phase_end" and currentPhases[e.phase] then
            if not phaseSummaries[e.phase] then
                phaseSummaries[e.phase] = {}
            end
            local ps = phaseSummaries[e.phase]
            ps[#ps + 1] = {
                duration = e.duration,
            }
            -- Include all delta fields
            for k, v in pairs(e) do
                if type(v) == "number" and k:match("_delta$") then
                    ps[#ps][k] = v
                end
            end
            currentPhases[e.phase] = nil
        end
    end

    local summary = {
        player = T.playerTag,
        duration = T.gameTime,
        eventCounts = counts,
        totalEvents = #T.events,
        phases = phaseSummaries,
        timestamp = os.time(),
    }

    if T.summaryFn then
        local extra = T.summaryFn()
        if extra then
            for k, v in pairs(extra) do summary[k] = v end
        end
    end

    return summary
end

------------------------------------------------------
-- BATCH STATISTICS
------------------------------------------------------
-- Compute aggregate stats across all runs in a batch.
-- Finds all numeric fields in run summaries and computes
-- mean, stddev, min, max for each.

function T.batchStats()
    if #T.runResults == 0 then return {} end

    -- Collect all numeric fields across runs
    local fields = {}
    for _, run in ipairs(T.runResults) do
        for k, v in pairs(run) do
            if type(v) == "number" and k ~= "timestamp" then
                if not fields[k] then fields[k] = {} end
                fields[k][#fields[k] + 1] = v
            end
        end
    end

    local stats = { n = #T.runResults }
    for field, values in pairs(fields) do
        local sum = 0
        local min, max = math.huge, -math.huge
        for _, v in ipairs(values) do
            sum = sum + v
            if v < min then min = v end
            if v > max then max = v end
        end
        local mean = sum / #values
        local variance = 0
        for _, v in ipairs(values) do
            variance = variance + (v - mean) ^ 2
        end
        variance = variance / #values
        stats[field] = {
            mean = mean,
            stddev = math.sqrt(variance),
            min = min,
            max = max,
            n = #values,
        }
    end
    return stats
end

--- Pretty-print batch stats to a string.
function T.formatBatchStats()
    local stats = T.batchStats()
    if not stats.n then return "No runs recorded." end

    local lines = { "Batch Statistics (" .. stats.n .. " runs):" }
    local keys = {}
    for k, v in pairs(stats) do
        if type(v) == "table" then keys[#keys + 1] = k end
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
        local s = stats[k]
        lines[#lines + 1] = string.format(
            "  %-20s  mean=%.2f  stddev=%.2f  min=%.2f  max=%.2f",
            k, s.mean, s.stddev, s.min, s.max
        )
    end
    return table.concat(lines, "\n")
end

------------------------------------------------------
-- BALANCE ASSERTIONS
------------------------------------------------------

--- Register a balance assertion.
-- @param name string  descriptive name for the assertion
-- @param fn function(runSummary) -> boolean  must return true to pass
-- @param mode string  "every" (default) or "majority"
function T.addAssertion(name, fn, mode)
    T.assertions[#T.assertions + 1] = {
        name = name,
        fn = fn,
        mode = mode or "every",
    }
end

--- Run all assertions against accumulated run results.
--- Returns { passed = bool, results = { {name, passed, detail} } }
function T.checkAssertions()
    local results = {}
    local allPassed = true

    for _, assertion in ipairs(T.assertions) do
        local passCount = 0
        local failCount = 0
        local failDetails = {}

        for i, run in ipairs(T.runResults) do
            local ok = assertion.fn(run)
            if ok then
                passCount = passCount + 1
            else
                failCount = failCount + 1
                failDetails[#failDetails + 1] = i
            end
        end

        local passed
        if assertion.mode == "majority" then
            passed = passCount > failCount
        else -- "every"
            passed = failCount == 0
        end

        if not passed then allPassed = false end

        results[#results + 1] = {
            name = assertion.name,
            passed = passed,
            passCount = passCount,
            failCount = failCount,
            failRuns = failDetails,
            mode = assertion.mode,
        }
    end

    return { passed = allPassed, results = results }
end

--- Format assertion results as a readable string.
function T.formatAssertions()
    local check = T.checkAssertions()
    if #check.results == 0 then return "No assertions defined." end

    local lines = { "Balance Assertions:" }
    for _, r in ipairs(check.results) do
        local status = r.passed and "PASS" or "FAIL"
        local detail = string.format("%d/%d passed", r.passCount, r.passCount + r.failCount)
        if r.mode == "majority" then detail = detail .. " (majority)" end
        lines[#lines + 1] = string.format("  [%s] %s — %s", status, r.name, detail)
        if not r.passed and #r.failRuns > 0 then
            local failStr = {}
            for _, ri in ipairs(r.failRuns) do failStr[#failStr + 1] = tostring(ri) end
            lines[#lines + 1] = "         Failed runs: " .. table.concat(failStr, ", ")
        end
    end
    lines[#lines + 1] = check.passed and "All assertions passed." or "SOME ASSERTIONS FAILED."
    return table.concat(lines, "\n")
end

------------------------------------------------------
-- EXPORT
------------------------------------------------------

function T.writeFile(filename, contents)
    if T.writeFn then
        T.writeFn(filename, contents)
        return
    end
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

function T.saveResults()
    local lines = {}
    local function w(s) lines[#lines + 1] = s end

    w("return {")
    for i, run in ipairs(T.runResults) do
        w("  { -- Run " .. i)
        for k, v in pairs(run) do
            if k ~= "eventCounts" and k ~= "phases" then
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
        if run.phases then
            w("    phases = {")
            for pname, plist in pairs(run.phases) do
                w("      " .. pname .. " = {")
                for _, p in ipairs(plist) do
                    local parts = {}
                    for pk, pv in pairs(p) do
                        parts[#parts + 1] = pk .. "=" .. T.serialize(pv)
                    end
                    w("        { " .. table.concat(parts, ", ") .. " },")
                end
                w("      },")
            end
            w("    },")
        end
        w("  },")
    end
    w("}")

    T.writeFile(T.outputFile, table.concat(lines, "\n") .. "\n")
end

function T.serialize(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = {}
        for i, item in ipairs(v) do
            parts[#parts + 1] = T.serialize(item)
        end
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

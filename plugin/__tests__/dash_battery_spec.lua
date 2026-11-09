-- Run: scripts/test.sh
package.path = "plugin/dash.koplugin/?.lua;" .. package.path
local Battery = require("dash_battery")

local failures, passed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
    end
end

local T0 = 1794000000

-- Feeds one reading a minute, as the dashboard's clock does.
local function feed(battery, from, minutes, level_at, charging)
    for minute = 0, minutes do
        battery:record(from + minute * 60, level_at(minute), charging)
    end
end

test("only stores a reading when the level changes", function()
    local battery = Battery.new()
    eq(battery:record(T0, 50, false), true, "first reading")
    eq(battery:record(T0 + 60, 50, false), false, "same level")
    eq(battery:record(T0 + 120, 49, false), true, "a drop")
    eq(#battery.runs, 1, "runs")
    eq(#battery.runs[1].points, 2, "points")
end)

test("measures between drops, not from the first reading", function()
    local battery = Battery.new()
    -- Starts at 50 but drops at minute 5, 20 and 35: one percent every 15 minutes.
    feed(battery, T0, 40, function(m) return m < 5 and 50 or m < 20 and 49 or m < 35 and 48 or 47 end, false)
    local summary = battery:summary(T0 + 40 * 60)
    eq(summary.per_hour, 4, "per hour")
    eq(summary.level, 47, "level")
    eq(summary.hours_left, 47 / 4, "hours left")
    eq(summary.awake_seconds, 40 * 60, "awake")
end)

test("regression: a level flickering back up doesn't skew the rate", function()
    local battery = Battery.new()
    -- Seen on the Kindle: 37, 36 a minute later, back to 37, then a steady decline.
    -- New lows are 36 at minute 1, 35 at minute 31 and 34 at minute 61: 2% in an hour.
    -- It ends flickering back up to 35, which once halved the rate.
    local levels = { [0] = 37, [1] = 36, [4] = 37, [20] = 36, [31] = 35, [40] = 36, [45] = 35, [61] = 34, [63] = 35 }
    local level = 37
    for minute = 0, 65 do
        level = levels[minute] or level
        battery:record(T0 + minute * 60, level, false)
    end
    local summary = battery:summary(T0 + 65 * 60)
    eq(summary.per_hour, 2, "per hour")
    eq(summary.level, 35, "level")
end)

test("a flicker alone gives no rate", function()
    local battery = Battery.new()
    feed(battery, T0, 10, function(m) return (m == 1 or m == 6) and 36 or 37 end, false)
    eq(battery:summary(T0 + 10 * 60).per_hour, nil, "per hour")
end)

test("needs two drops before giving a rate", function()
    local battery = Battery.new()
    feed(battery, T0, 30, function(m) return m < 10 and 50 or 49 end, false)
    local summary = battery:summary(T0 + 30 * 60)
    eq(summary.per_hour, nil, "per hour")
    eq((Battery.describe(summary)), "Drain: measuring…", "headline")
end)

test("charging starts a new run with no drain rate", function()
    local battery = Battery.new()
    feed(battery, T0, 40, function(m) return 50 - math.floor(m / 10) end, false)
    battery:record(T0 + 41 * 60, 46, true)
    eq(#battery.runs, 2, "runs")
    local summary = battery:summary(T0 + 41 * 60)
    eq(summary.charging, true, "charging")
    eq(summary.per_hour, nil, "per hour")
    eq((Battery.describe(summary)), "Charging", "headline")
end)

test("a gap such as sleep starts a new run", function()
    local battery = Battery.new()
    feed(battery, T0, 40, function(m) return 50 - math.floor(m / 10) end, false)
    battery:record(T0 + 3 * 3600, 45, false)
    eq(#battery.runs, 2, "runs")
    eq(battery:summary(T0 + 3 * 3600).per_hour, nil, "rate carried across the gap")
end)

test("no summary once readings stop", function()
    local battery = Battery.new()
    battery:record(T0, 50, false)
    eq(battery:summary(T0 + 10 * 60), nil, "summary")
    eq((Battery.describe(nil)), "Drain: —", "headline")
end)

test("a clock that goes backwards starts a new run", function()
    local battery = Battery.new()
    battery:record(T0, 50, false)
    battery:record(T0 - 3600, 50, false)
    eq(#battery.runs, 2, "runs")
end)

test("drops runs older than two days", function()
    local battery = Battery.new()
    battery:record(T0, 50, false)
    battery:record(T0 + 3 * 86400, 40, false)
    eq(#battery.runs, 1, "runs")
    eq(battery.runs[1].start, T0 + 3 * 86400, "kept the new run")
end)

test("describes the drain for the tile", function()
    local headline, detail = Battery.describe({ charging = false, level = 46, awake_seconds = 7800, per_hour = 4.12, hours_left = 11.17 })
    eq(headline, "Drain: −4.1%/h", "headline")
    eq(detail, "about 11 h left · 2h 10m awake", "detail")
    local _, short = Battery.describe({ charging = false, level = 8, awake_seconds = 600, per_hour = 4, hours_left = 2 })
    eq(short, "about 2.0 h left · 10m awake", "detail under 10 hours")
end)

test("history survives a save and load", function()
    local path = assert(os.getenv("KDASH_TEST_DIR"), "KDASH_TEST_DIR is required") .. "/battery_spec.json"
    local battery = Battery.new{ path = path }
    feed(battery, T0, 40, function(m) return 50 - math.floor(m / 10) end, false)
    assert(battery:save())
    local loaded = Battery.new{ path = path }
    loaded:load()
    eq(#loaded.runs[1].points, #battery.runs[1].points, "points")
    eq(loaded:summary(T0 + 40 * 60).per_hour, battery:summary(T0 + 40 * 60).per_hour, "rate")
end)

test("a corrupt history file is ignored", function()
    local path = os.getenv("KDASH_TEST_DIR") .. "/battery_bad.json"
    local file = io.open(path, "w")
    file:write("{not json")
    file:close()
    local battery = Battery.new{ path = path }
    battery:load()
    eq(#battery.runs, 0, "runs")
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

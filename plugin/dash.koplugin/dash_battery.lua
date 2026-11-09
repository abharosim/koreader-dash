-- Battery drain tracking. Readings are grouped into runs: stretches of time awake on battery
-- (or on the charger) with no gaps. A run ends when charging starts or stops, or when no
-- reading arrives for MAX_GAP_SECONDS, such as after sleep or with the dashboard closed.
-- Only percentage changes are stored, so a day of history is a few KB.
-- Has no KOReader imports.

local json = require("json")

local MAX_GAP_SECONDS = 5 * 60
local KEEP_SECONDS = 48 * 3600
-- The level is a whole number, so the rate is measured between two drops, never from
-- the first reading, which could be anywhere within its percent.
local MIN_DROPS = 2

local Battery = {}
Battery.__index = Battery

-- opts: path (where history is saved; optional)
function Battery.new(opts)
    return setmetatable({ path = opts and opts.path, runs = {} }, Battery)
end

function Battery:load()
    local file = self.path and io.open(self.path, "r")
    if not file then
        return
    end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" and type(data.runs) == "table" then
        self.runs = data.runs
    end
end

function Battery:save()
    if not self.path then
        return true
    end
    local temp_path = self.path .. ".tmp"
    local file, err = io.open(temp_path, "w")
    if not file then
        return false, err
    end
    file:write(json.encode({ runs = self.runs }))
    file:close()
    return os.rename(temp_path, self.path)
end

-- Adds a reading. Returns true when the history changed enough to be worth saving.
function Battery:record(now, level, charging)
    charging = charging and true or false
    local run = self.runs[#self.runs]
    if not run or run.charging ~= charging or now - run.last > MAX_GAP_SECONDS or now < run.last then
        run = { charging = charging, start = now, last = now, points = { { now, level } } }
        table.insert(self.runs, run)
        while self.runs[1] and self.runs[1].last < now - KEEP_SECONDS do
            table.remove(self.runs, 1)
        end
        return true
    end
    run.last = now
    if run.points[#run.points][2] ~= level then
        table.insert(run.points, { now, level })
        return true
    end
    return false
end

-- Returns a table describing the current run, or nil when there's no recent reading.
--   charging, level, awake_seconds,
--   per_hour and hours_left once at least MIN_DROPS drops have been seen on battery.
function Battery:summary(now)
    local run = self.runs[#self.runs]
    if not run or now - run.last > MAX_GAP_SECONDS then
        return nil
    end
    local points = run.points
    local result = {
        charging = run.charging,
        level = points[#points][2],
        awake_seconds = run.last - run.start,
    }
    if run.charging then
        return result
    end
    -- The level flickers between neighbouring values, so only new lows count as drops,
    -- each timed from the first moment that level was reached.
    local lows, lowest = {}, points[1][2]
    for i = 2, #points do
        if points[i][2] < lowest then
            lowest = points[i][2]
            table.insert(lows, points[i])
        end
    end
    if #lows < MIN_DROPS then
        return result
    end
    local first, last = lows[1], lows[#lows]
    local hours = (last[1] - first[1]) / 3600
    local dropped = first[2] - last[2]
    if hours > 0 and dropped > 0 then
        result.per_hour = dropped / hours
        result.hours_left = result.level / result.per_hour
    end
    return result
end

local function duration(seconds)
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return string.format("%dm", minutes)
    end
    return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

-- Two lines for the dashboard tile: a headline and a detail line.
function Battery.describe(summary)
    if not summary then
        return "Drain: —", " "
    end
    if summary.charging then
        return "Charging", string.format("%d%% · plugged in %s", summary.level, duration(summary.awake_seconds))
    end
    local awake = duration(summary.awake_seconds) .. " awake"
    if not summary.per_hour then
        return "Drain: measuring…", string.format("%d%% · %s", summary.level, awake)
    end
    local hours_left = summary.hours_left
    local left = hours_left >= 10 and string.format("%d h", math.floor(hours_left + 0.5))
        or string.format("%.1f h", hours_left)
    return string.format("Drain: −%.1f%%/h", summary.per_hour),
        string.format("about %s left · %s", left, awake)
end

return Battery

-- US Eastern time and month layouts, independent of the Kindle's own time zone.
-- Pure functions: the device clock supplies the instant, and these only change how it's shown.

local Time = {}

local HOUR = 3600
local DAY = 86400

-- Days since 1970-01-01 for a calendar date.
function Time.daysFromCivil(year, month, day)
    if month <= 2 then
        year = year - 1
    end
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local shifted_month = (month + 9) % 12
    local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
    return era * 146097 + day_of_era - 719468
end

-- 0 is Sunday. 1970-01-01 was a Thursday.
local function weekday(year, month, day)
    return (Time.daysFromCivil(year, month, day) + 4) % 7
end

local function firstSunday(year, month)
    return 1 + (7 - weekday(year, month, 1)) % 7
end

-- Daylight time runs from 2am on March's second Sunday to 2am on November's first Sunday.
function Time.easternOffset(utc_seconds)
    local year = os.date("!*t", utc_seconds).year
    local starts = Time.daysFromCivil(year, 3, firstSunday(year, 3) + 7) * DAY + 7 * HOUR
    local ends = Time.daysFromCivil(year, 11, firstSunday(year, 11)) * DAY + 6 * HOUR
    if utc_seconds >= starts and utc_seconds < ends then
        return -4 * HOUR
    end
    return -5 * HOUR
end

function Time.format(format, utc_seconds)
    utc_seconds = utc_seconds or os.time()
    return os.date("!" .. format, utc_seconds + Time.easternOffset(utc_seconds))
end

function Time.fields(utc_seconds)
    utc_seconds = utc_seconds or os.time()
    return os.date("!*t", utc_seconds + Time.easternOffset(utc_seconds))
end

-- Returns week rows, Sunday first. Days outside the month are false.
function Time.monthWeeks(year, month)
    local next_year, next_month = year, month + 1
    if next_month > 12 then
        next_year, next_month = year + 1, 1
    end
    local day_count = Time.daysFromCivil(next_year, next_month, 1) - Time.daysFromCivil(year, month, 1)

    local weeks, week = {}, {}
    for _ = 1, weekday(year, month, 1) do
        table.insert(week, false)
    end
    for day = 1, day_count do
        table.insert(week, day)
        if #week == 7 then
            table.insert(weeks, week)
            week = {}
        end
    end
    if #week > 0 then
        while #week < 7 do
            table.insert(week, false)
        end
        table.insert(weeks, week)
    end
    return weeks
end

return Time

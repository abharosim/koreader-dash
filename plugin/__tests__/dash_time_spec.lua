-- Run: scripts/test.sh
local Time = dofile("plugin/dash.koplugin/dash_time.lua")

local failures, passed = 0, 0

local function check(name, actual, expected)
    if actual == expected then
        passed = passed + 1
        print("ok    " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL  %s\n      expected %q, got %q", name, tostring(expected), tostring(actual)))
    end
end

local function utc(year, month, day, hour, minute, second)
    return Time.daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

local FORMAT = "%Y-%m-%d %H:%M:%S %A"

check("epoch day is zero", Time.daysFromCivil(1970, 1, 1), 0)
check("matches a known timestamp", utc(2026, 11, 7, 19, 24, 13), 1794079453)

check("winter shows standard time",
    Time.format(FORMAT, utc(2026, 11, 7, 19, 24, 13)), "2026-11-07 14:24:13 Saturday")
check("summer shows daylight time",
    Time.format(FORMAT, utc(2026, 7, 4, 16, 0, 0)), "2026-07-04 12:00:00 Saturday")

check("last second before spring change",
    Time.format(FORMAT, utc(2026, 3, 8, 6, 59, 59)), "2026-03-08 01:59:59 Sunday")
check("clocks jump forward in spring",
    Time.format(FORMAT, utc(2026, 3, 8, 7, 0, 0)), "2026-03-08 03:00:00 Sunday")
check("last second before autumn change",
    Time.format(FORMAT, utc(2026, 11, 1, 5, 59, 59)), "2026-11-01 01:59:59 Sunday")
check("clocks fall back in autumn",
    Time.format(FORMAT, utc(2026, 11, 1, 6, 0, 0)), "2026-11-01 01:00:00 Sunday")

check("evening in New York is still the previous year",
    Time.format(FORMAT, utc(2027, 1, 1, 0, 30, 0)), "2026-12-31 19:30:00 Thursday")
check("fields use Eastern day", Time.fields(utc(2026, 11, 8, 2, 0, 0)).day, 7)

local november = Time.monthWeeks(2026, 11)
check("November 2026 starts on Sunday", november[1][1], 1)
check("November 2026 has 5 weeks", #november, 5)
check("November 2026 ends on the 30th", november[5][2], 30)
check("trailing days are blank", november[5][3], false)

local leap = Time.monthWeeks(2028, 2)
check("February 2028 starts on Tuesday", leap[1][3], 1)
check("leading days are blank", leap[1][2], false)
check("February 2028 has a 29th", leap[5][3], 29)

local december = Time.monthWeeks(2026, 12)
check("December crosses into the next year correctly", december[#december][5], 31)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

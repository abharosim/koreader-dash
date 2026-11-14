-- Run: scripts/test.sh
package.path = "plugin/dash.koplugin/?.lua;" .. package.path
local Usage = require("dash_usage")
local Time = require("dash_time")

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

local function utc(year, month, day, hour, minute)
    return Time.daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60
end

-- Saturday 14 November 2026, 01:30 Eastern.
local now = utc(2026, 11, 14, 6, 30)
local GROK = Usage.PROVIDERS[1]

local tiles = Usage.describeAll(nil, now)
check("four tiles with no usage data", #tiles, 4)
check("tiles are in a fixed order", tiles[1].title .. "," .. tiles[2].title .. "," .. tiles[3].title .. "," .. tiles[4].title,
    "Grok,Claude,DeepSeek,Gemini")
check("a provider with no data says so", tiles[2].headline, "No data yet")
check("no data is marked missing", tiles[2].missing, true)
check("no data has no bar", tiles[2].pct, nil)

local plan = Usage.describe(GROK, {
    used_pct = 17.4, resets_at = utc(2026, 11, 20, 23, 24), updated_at = now - 60, label = "Grok Bot",
}, now)
check("percent becomes the headline", plan.headline, "17%")
check("percent drives the bar", plan.pct, 17.4)
check("a label replaces the title", plan.title, "Grok Bot")
check("a reset over 6 days away shows the date", plan.line, "resets Nov 20")
check("updated today shows the time", plan.updated, "01:29")
check("fresh data isn't stale", plan.stale, false)

local soon = Usage.describe(GROK, { used_pct = 50, resets_at = utc(2026, 11, 15, 1, 0), updated_at = now }, now)
check("a reset within days shows weekday and time", soon.line, "resets Sat 20:00")

local both = Usage.describe(GROK, { used_pct = 50, detail = "week", resets_at = utc(2026, 11, 15, 1, 0) }, now)
check("detail and reset share one line", both.line, "week · resets Sat 20:00")

check("percent is clamped", Usage.describe(GROK, { used_pct = 140 }, now).pct, 100)
check("percent rounds", Usage.describe(GROK, { used_pct = 99.6 }, now).headline, "100%")

local balance = Usage.describe(GROK, { balance = 110, currency = "CNY", updated_at = now }, now)
check("balance in yuan", balance.headline, "¥110.00 left")
check("balance has no bar", balance.pct, nil)
check("unknown currency keeps its code",
    Usage.describe(GROK, { balance = 5, currency = "CHF" }, now).headline, "5.00 CHF left")
check("spend defaults to dollars", Usage.describe(GROK, { spent = 3.2 }, now).headline, "$3.20 spent")
check("a sender's headline wins", Usage.describe(GROK, { used_pct = 35, headline = "35% · 5h 9%" }, now).headline,
    "35% · 5h 9%")
check("an entry with nothing usable shows a dash", Usage.describe(GROK, { note = 1 }, now).headline, "—")

local old = Usage.describe(GROK, { used_pct = 10, updated_at = now - 2 * 86400 }, now)
check("data over a day old is stale", old.stale, true)
check("stale data says so with its date", old.updated, "stale Nov 12")
check("expires_at overrides the default age",
    Usage.describe(GROK, { used_pct = 10, updated_at = now - 2 * 86400, expires_at = now + 60 }, now).stale, false)
local reset = Usage.describe(GROK, { used_pct = 90, resets_at = now - 60, updated_at = now - 3600 }, now)
check("a passed reset makes the numbers stale", reset.stale, true)
check("a passed reset isn't shown", reset.line, nil)

-- Network data can hold anything.
local junk = Usage.describe(GROK, { used_pct = "17", label = { "x" }, detail = 5, resets_at = "soon", balance = 0 / 0 }, now)
check("non-number percent is ignored", junk.pct, nil)
check("non-string label falls back", junk.title, "Grok")
check("non-string detail is ignored", junk.line, nil)
check("NaN balance is ignored", junk.headline, "—")
check("a non-table entry is missing", Usage.describe(GROK, "17%", now).missing, true)
check("long text is cut", #Usage.describe(GROK, { headline = string.rep("x", 200) }, now).headline, 40)
check("whitespace collapses", Usage.describe(GROK, { detail = "a\n\n b" }, now).line, "a b")

check("signature marks fresh tiles", Usage.signature({ grok = { used_pct = 1, updated_at = now } }, now), "ffff")
check("signature changes when a tile goes stale",
    Usage.signature({ grok = { used_pct = 1, updated_at = now } }, now + 86400), "sfff")

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

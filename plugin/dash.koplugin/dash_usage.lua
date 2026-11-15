-- AI usage tiles: turns the `usage` field of the state blob into short lines for the dashboard.
-- Pure functions with no KOReader imports. Network data can hold any JSON type, so every
-- field is type-checked and anything unexpected is ignored.

local DashTime = require("dash_time")

local Usage = {}

-- Tile order on the dashboard, and the title shown when a sender doesn't give a label.
Usage.PROVIDERS = {
    { key = "grok", title = "Grok" },
    { key = "anthropic", title = "Claude" },
    { key = "deepseek", title = "DeepSeek" },
    { key = "xai", title = "xAI API" },
}

-- Values older than this are marked stale, unless the sender sets its own expires_at.
Usage.STALE_AFTER_SECONDS = 24 * 3600

local CURRENCY_SYMBOLS = { USD = "$", CNY = "¥", EUR = "€", GBP = "£", JPY = "¥" }

local function text(value, max_bytes)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    value = value:gsub("%s+", " ")
    if max_bytes and #value > max_bytes then
        value = value:sub(1, max_bytes)
    end
    return value
end

local function number(value)
    if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
        return value
    end
    return nil
end

function Usage.money(amount, currency)
    currency = text(currency, 8) or "USD"
    local symbol = CURRENCY_SYMBOLS[currency:upper()]
    if symbol then
        return (amount < 0 and "-" or "") .. symbol .. string.format("%.2f", math.abs(amount))
    end
    return string.format("%.2f %s", amount, currency)
end

-- "Fri 18:24" within the next 6 days, otherwise "Nov 28".
local function whenText(at, now)
    if at - now < 6 * 86400 then
        return DashTime.format("%a %H:%M", at)
    end
    return DashTime.format("%b %d", at)
end

-- "01:20" today, otherwise "Nov 12".
local function updatedText(at, now)
    local updated, today = DashTime.fields(at), DashTime.fields(now)
    if updated.year == today.year and updated.month == today.month and updated.day == today.day then
        return DashTime.format("%H:%M", at)
    end
    return DashTime.format("%b %d", at)
end

-- Describes one provider's tile. Returns a table with:
--   title, updated (when it was sent, for the title row), headline,
--   line (the sender's detail and the reset time, or nil),
--   pct (0-100 or nil), stale (old, expired, or past its reset), missing (nothing sent yet).
function Usage.describe(provider, entry, now)
    now = now or os.time()
    if type(entry) ~= "table" then
        return {
            title = provider.title,
            updated = "",
            headline = "No data yet",
            missing = true,
            stale = false,
        }
    end

    local result = { title = text(entry.label, 24) or provider.title, missing = false }
    local pct = number(entry.used_pct)
    if pct then
        result.pct = math.max(0, math.min(100, pct))
    end
    local balance, spent = number(entry.balance), number(entry.spent)

    result.headline = text(entry.headline, 40)
            -- Just the number: the bar beneath shows it's the share used.
        or (result.pct and string.format("%d%%", math.floor(result.pct + 0.5)))
        or (balance and Usage.money(balance, entry.currency) .. " left")
        or (spent and Usage.money(spent, entry.currency) .. " spent")
        or "—"

    local resets_at = number(entry.resets_at)
    local reset_passed = resets_at and resets_at <= now
    local resets = resets_at and not reset_passed and ("RE " .. whenText(resets_at, now)) or nil
    local detail = text(entry.detail, 60)
    -- One line keeps the tiles short; senders should keep the detail brief.
    if detail and resets then
        result.line = detail .. " · " .. resets
    else
        result.line = detail or resets
    end

    local updated_at = number(entry.updated_at)
    local expires_at = number(entry.expires_at)
        or (updated_at and updated_at + Usage.STALE_AFTER_SECONDS)
    result.stale = (expires_at ~= nil and now >= expires_at) or reset_passed or false
    if updated_at then
        result.updated = (result.stale and "stale " or "") .. updatedText(updated_at, now)
    else
        result.updated = result.stale and "stale" or ""
    end
    return result
end

-- Every tile, in dashboard order.
function Usage.describeAll(usage, now)
    usage = type(usage) == "table" and usage or {}
    local tiles = {}
    for _, provider in ipairs(Usage.PROVIDERS) do
        table.insert(tiles, Usage.describe(provider, usage[provider.key], now))
    end
    return tiles
end

-- Changes when any tile turns stale or fresh, so the dashboard knows to rebuild.
function Usage.signature(usage, now)
    local parts = {}
    for _, tile in ipairs(Usage.describeAll(usage, now)) do
        table.insert(parts, tile.stale and "s" or "f")
    end
    return table.concat(parts)
end

return Usage

-- Keeps the Kindle awake while the dashboard is open.
-- See SPEC.md, "Staying on", for why each setting is needed.

local DataStorage = require("datastorage")
local Device = require("device")
local PluginShare = require("pluginshare")

local PREVENT_SCREENSAVER = "lipc-set-prop com.lab126.powerd preventScreenSaver %d"

local function markerPath()
    return DataStorage:getSettingsDir() .. "/dash_keepawake.marker"
end

local function setKindleScreensaverBlocked(blocked)
    if Device:isKindle() then
        os.execute(string.format(PREVENT_SCREENSAVER, blocked and 1 or 0))
    end
end

local Power = {
    active = false,
    previous_keepalive = nil,
    previous_pause = nil,
}

-- A marker left behind means KOReader died with the screensaver blocked.
function Power.recoverFromCrash()
    local marker = io.open(markerPath(), "r")
    if marker then
        marker:close()
        setKindleScreensaverBlocked(false)
        os.remove(markerPath())
        return true
    end
    return false
end

function Power.enable()
    if Power.active then
        return
    end
    Power.active = true
    Power.previous_keepalive = PluginShare.keepalive
    Power.previous_pause = PluginShare.pause_auto_suspend

    local marker = io.open(markerPath(), "w")
    if marker then
        marker:close()
    end
    PluginShare.pause_auto_suspend = true
    if Device:isKindle() then
        PluginShare.keepalive = true
        setKindleScreensaverBlocked(true)
    end
end

function Power.disable()
    if not Power.active then
        return
    end
    Power.active = false
    PluginShare.pause_auto_suspend = Power.previous_pause
    if Device:isKindle() then
        PluginShare.keepalive = Power.previous_keepalive
        -- Leave it blocked if the user's KeepAlive plugin was already on.
        if not Power.previous_keepalive then
            setKindleScreensaverBlocked(false)
        end
    end
    os.remove(markerPath())
end

return Power

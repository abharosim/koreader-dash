-- Plugin lifecycle: opens the dashboard and runs the server, store and keep-awake while it's open.

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local json = require("json")
local socket = require("socket")
local _ = require("gettext")

local DashTime = require("dash_time")
local Api = require("dash_api")
local Battery = require("dash_battery")
local Dashboard = require("dash_dashboard")
local DashHome = require("dash_home")
local Power = require("dash_power")
local Server = require("dash_server")
local Store = require("dash_store")

local PORT = 8787
local POLL_SECONDS = 0.25
local SAVE_DELAY_SECONDS = 5
-- scripts/deploy.sh creates this file to ask KOReader to restart and load the new code.
local RESTART_REQUEST_FILE = "dash_restart_request"
local RESTART_CHECK_SECONDS = 2
-- Below this, sleeping wins over opening Dash unless the Kindle is charging.
local LOW_BATTERY_PERCENT = 20
local REPLACES_SLEEP_SETTING = "dash_replaces_sleep"
local FIREWALL_RULES = {
    "INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
    "OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
}

-- KOReader creates a plugin instance per file browser or reader, so shared state lives here.
local Runtime = {
    dashboard = nil,
    server = nil,
    store = nil,
    battery = nil,
    api = nil,
    server_error = nil,
    save_scheduled = false,
    polling = false,
    pings = 0,
    watching_restart = false,
    last_ping = nil,
}

Power.recoverFromCrash()

local function restartRequestPath()
    return DataStorage:getSettingsDir() .. "/" .. RESTART_REQUEST_FILE
end
-- A request made while older code was running has been answered by this start.
os.remove(restartRequestPath())

local function logEvent(message)
    local log = io.open(DataStorage:getSettingsDir() .. "/dash_m0.log", "a")
    if not log then
        return
    end
    local powerd = Device:getPowerDevice()
    log:write(string.format("%s %s wifi=%s batt=%s charging=%s pings=%d server=%s\n",
        DashTime.format("%Y-%m-%dT%H:%M:%S"),
        message,
        tostring(NetworkMgr:isConnected()),
        tostring(powerd:getCapacity()),
        tostring(powerd:isCharging()),
        Runtime.pings,
        tostring(Runtime.server ~= nil and Runtime.server:isRunning())))
    log:close()
end

local function setFirewall(open)
    if not Device:isKindle() then
        return
    end
    for _, rule in ipairs(FIREWALL_RULES) do
        local formatted = string.format(rule, PORT)
        -- Delete first so restarts can't leave duplicates behind.
        os.execute("iptables -D " .. formatted .. " 2>/dev/null")
        if open then
            os.execute("iptables -A " .. formatted)
        end
    end
end

local function localIp()
    local udp = socket.udp()
    if not udp then
        return nil
    end
    udp:settimeout(0)
    -- Sends no packets; it asks the OS which interface it would route through.
    local ok = udp:setpeername("203.0.113.1", 53)
    local ip = ok and udp:getsockname()
    udp:close()
    if ip and ip ~= "0.0.0.0" then
        return ip
    end
    return nil
end

local function statusText()
    local lines = {
        NetworkMgr:isConnected() and string.format("Wi-Fi on  %s:%d", localIp() or "no address", PORT) or "Wi-Fi off",
        string.format("Pings: %d%s", Runtime.pings,
            Runtime.last_ping and ("  last " .. DashTime.format("%H:%M", Runtime.last_ping)) or ""),
    }
    if Runtime.server_error then
        table.insert(lines, "Server error: " .. Runtime.server_error)
    end
    if Runtime.store and Runtime.store.warning then
        table.insert(lines, Runtime.store.warning)
    end
    return table.concat(lines, "\n")
end

-- Reads the saved token, or creates one. Returns nil if no secure randomness is available.
local function loadToken()
    local path = DataStorage:getSettingsDir() .. "/dash_config.json"
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local ok, config = pcall(json.decode, content)
        if ok and type(config) == "table" and type(config.token) == "string" and #config.token >= 32 then
            return config.token
        end
    end

    local random = io.open("/dev/urandom", "rb")
    local bytes = random and random:read(16)
    if random then
        random:close()
    end
    if not bytes or #bytes ~= 16 then
        return nil
    end
    local token = bytes:gsub(".", function(char) return string.format("%02x", char:byte()) end)

    local temp_path = path .. ".tmp"
    local temp = io.open(temp_path, "w")
    if not temp then
        return nil
    end
    temp:write(json.encode({ token = token }))
    temp:close()
    if not os.rename(temp_path, path) then
        return nil
    end
    return token
end

local function saveNow()
    Runtime.save_scheduled = false
    if Runtime.store then
        local ok, err = Runtime.store:flush()
        if not ok then
            logger.warn("Dash: failed to save:", err)
        end
    end
end

local function onStoreChange()
    if not Runtime.save_scheduled then
        Runtime.save_scheduled = true
        UIManager:scheduleIn(SAVE_DELAY_SECONDS, saveNow)
    end
    if Runtime.dashboard then
        Runtime.dashboard:scheduleRebuild()
    end
end

local function ensureData()
    if Runtime.store then
        return true
    end
    local store = Store.new{
        path = DataStorage:getSettingsDir() .. "/dash_data.json",
        body_dir = DataStorage:getSettingsDir() .. "/dash_messages",
        make_dir = function(path)
            if lfs.attributes(path, "mode") ~= "directory" then
                lfs.mkdir(path)
            end
        end,
        on_change = onStoreChange,
    }
    store:load()
    Runtime.store = store

    Runtime.battery = Battery.new{ path = DataStorage:getSettingsDir() .. "/dash_battery.json" }
    Runtime.battery:load()

    local token = loadToken()
    if not token then
        Runtime.server_error = "Couldn't create an access token"
        return false
    end
    Runtime.api = Api.new{
        store = store,
        token = token,
        on_ping = function()
            Runtime.pings = Runtime.pings + 1
            Runtime.last_ping = os.time()
        end,
        info = function()
            local powerd = Device:getPowerDevice()
            local drain = Runtime.battery:summary(os.time())
            return {
                model = Device.model,
                battery = powerd:getCapacity(),
                charging = powerd:isCharging(),
                battery_drain_per_hour = drain and drain.per_hour
                    and math.floor(drain.per_hour * 10 + 0.5) / 10,
                battery_hours_left = drain and drain.hours_left
                    and math.floor(drain.hours_left * 10 + 0.5) / 10,
                wifi = NetworkMgr:isConnected(),
                dashboard_open = Runtime.dashboard ~= nil,
            }
        end,
    }
    return true
end

local function recordBattery()
    if not Runtime.battery then
        return
    end
    local powerd = Device:getPowerDevice()
    if Runtime.battery:record(os.time(), powerd:getCapacity(), powerd:isCharging()) then
        local ok, err = Runtime.battery:save()
        if not ok then
            logger.warn("Dash: failed to save battery history:", err)
        end
    end
end

local function drainText()
    return Battery.describe(Runtime.battery and Runtime.battery:summary(os.time()))
end

local function pollServer()
    if not Runtime.polling then
        return
    end
    local ok, err = pcall(Runtime.server.poll, Runtime.server)
    if not ok then
        logger.warn("Dash: server poll failed:", err)
    end
    UIManager:scheduleIn(POLL_SECONDS, pollServer)
end

local function startServer()
    if not Runtime.api then
        return
    end
    Runtime.server = Runtime.server or Server.new({
        port = PORT,
        handler = function(request) return Runtime.api:handle(request) end,
    })
    local ok, err = Runtime.server:start()
    if not ok then
        Runtime.server_error = tostring(err)
        logger.warn("Dash: failed to start server:", err)
        return
    end
    Runtime.server_error = nil
    setFirewall(true)
    if not Runtime.polling then
        Runtime.polling = true
        UIManager:scheduleIn(POLL_SECONDS, pollServer)
    end
end

local function stopServer()
    Runtime.polling = false
    UIManager:unschedule(pollServer)
    if Runtime.server and Runtime.server:isRunning() then
        Runtime.server:stop()
        setFirewall(false)
    end
end

-- Redraws SimpleUI's home screen, if it's in use, so its Dash module shows the latest data.
local function refreshHomeScreen()
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if type(ScreenEngine) == "table" and type(ScreenEngine.refresh) == "function" then
        local ok, err = pcall(ScreenEngine.refresh, true)
        if not ok then
            logger.warn("Dash: home screen refresh failed:", err)
        end
    end
end

local function closeDashboard()
    if not Runtime.dashboard then
        return
    end
    logEvent("close")
    stopServer()
    UIManager:unschedule(saveNow)
    saveNow()
    Power.disable()
    UIManager:close(Runtime.dashboard)
    Runtime.dashboard = nil
    refreshHomeScreen()
end

-- Removing the file is the check, so a request is handled exactly once.
local function checkRestartRequest()
    if not os.remove(restartRequestPath()) then
        UIManager:scheduleIn(RESTART_CHECK_SECONDS, checkRestartRequest)
        return
    end
    logEvent("restart requested")
    closeDashboard()
    -- The same event as Restart in KOReader's menu: the reader saves its place first.
    UIManager:broadcastEvent(Event:new("Restart"))
end

local function openDashboard()
    if Runtime.dashboard then
        return
    end
    ensureData()
    Power.enable()
    startServer()
    recordBattery()
    Runtime.dashboard = Dashboard:new{
        store = Runtime.store,
        get_status = statusText,
        get_drain = drainText,
        on_minute = function()
            recordBattery()
            logEvent("tick")
        end,
        on_close = closeDashboard,
        on_lock_change = function(locked) logEvent(locked and "lock" or "unlock") end,
    }
    UIManager:show(Runtime.dashboard)
    logEvent("open")
end

local function replacesSleep()
    return G_reader_settings:nilOrTrue(REPLACES_SLEEP_SETTING)
end

local function sleepOpensDash()
    if Runtime.dashboard or not replacesSleep() then
        return false
    end
    local powerd = Device:getPowerDevice()
    return powerd:isCharging() or powerd:getCapacity() >= LOW_BATTERY_PERCENT
end

-- KOReader's idle timer, the Sleep menu item and the Sleep gesture all go through
-- UIManager:suspend, so Dash opens there instead. The power button is handled by the
-- Kindle itself and still sleeps. Sleeping while Dash is open sleeps for real.
local real_suspend = UIManager.suspend
function UIManager:suspend(...)
    if sleepOpensDash() then
        openDashboard()
        logEvent("sleep replaced")
        return
    end
    return real_suspend(self, ...)
end

local Dash = WidgetContainer:extend{
    name = "dash",
    is_doc_only = false,
}

local function openFromUser()
    if not NetworkMgr:isConnected() then
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is off, so the server won't be reachable until it reconnects."),
            timeout = 5,
        })
    end
    openDashboard()
end

-- Adds a Dash module to SimpleUI's home screen when that plugin is installed.
-- Every plugin's folder is on package.path by the time plugins are initialised.
-- Registering again replaces the module, so each plugin instance can call this.
local function registerHomeModule()
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if not ok or type(Registry) ~= "table" or type(Registry.register) ~= "function" then
        return
    end
    Registry.register(DashHome.new{
        get_data = function()
            ensureData()
            return Runtime.store and { store = Runtime.store, drain = (drainText()) }
        end,
        open = openFromUser,
    })
end

function Dash:init()
    registerHomeModule()
    if not Runtime.watching_restart then
        Runtime.watching_restart = true
        UIManager:scheduleIn(RESTART_CHECK_SECONDS, checkRestartRequest)
    end
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- Makes "Open Dash" available to gestures, Quick menus and profiles.
function Dash:onDispatcherRegisterActions()
    Dispatcher:registerAction("dash_open", {
        category = "none",
        event = "OpenDash",
        title = _("Open Dash"),
        general = true,
    })
end

function Dash:onOpenDash()
    openFromUser()
    return true
end

function Dash:addToMainMenu(menu_items)
    menu_items.dash = {
        text = _("Dash"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Open Dash"),
                callback = openFromUser,
            },
            {
                text = _("Open Dash instead of sleeping"),
                help_text = _("The idle timer and the Sleep action open Dash instead. The power button still sleeps. Below 20% battery, unplugged, it sleeps as usual."),
                checked_func = replacesSleep,
                callback = function() G_reader_settings:flipNilOrTrue(REPLACES_SLEEP_SETTING) end,
            },
        },
    }
end

function Dash:onSuspend()
    if Runtime.dashboard then
        logEvent("suspend")
        recordBattery()
        Runtime.dashboard:stopClock()
        stopServer()
        UIManager:unschedule(saveNow)
        saveNow()
    end
end

function Dash:onResume()
    if Runtime.dashboard then
        recordBattery()
        startServer()
        Runtime.dashboard:startClock()
        UIManager:setDirty(Runtime.dashboard, "full")
        logEvent("resume")
    end
end

function Dash:onExit()
    if Runtime.dashboard then
        logEvent("exit")
    end
    stopServer()
    UIManager:unschedule(saveNow)
    saveNow()
    Power.disable()
end

return Dash

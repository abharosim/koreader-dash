-- Runs the real plugin code with KOReader's modules replaced by stand-ins.
-- This checks the plugin's logic, not how it behaves on a Kindle.
local socket = require("socket")

local settings_dir = assert(os.getenv("KDASH_TEST_DIR"), "KDASH_TEST_DIR is required")
package.path = "plugin/dash.koplugin/?.lua;" .. package.path

local commands, scheduled, shown, closed = {}, {}, {}, {}
local real_execute = os.execute
os.execute = function(command) table.insert(commands, command); return 0 end

local function class()
    local c = {}
    c.__index = c
    function c:extend(fields)
        fields = fields or {}
        fields.__index = fields
        return setmetatable(fields, self)
    end
    function c:new(o)
        o = o or {}
        o.ges_events = o.ges_events or {}
        setmetatable(o, self)
        self.__index = self
        if o.init then o:init() end
        return o
    end
    function c:setText(text) self.text = text end
    function c:getSize() return { w = 200, h = 60 } end
    function c:free() end
    -- Passes events to children like a real container, recording what reached each widget.
    function c:handleEvent(event)
        self.received = (self.received or 0) + 1
        for _, child in ipairs(self) do
            if type(child) == "table" and child.handleEvent and child:handleEvent(event) then return true end
        end
        return false
    end
    return c
end

local PluginShare = {}
local registered_actions = {}
local Dispatcher = {}
function Dispatcher:registerAction(name, value) registered_actions[name] = value; return true end
local UIManager = {}
function UIManager:scheduleIn(_, fn) scheduled[fn] = true end
function UIManager:unschedule(fn) scheduled[fn] = nil end
local refreshes = {}
function UIManager:setDirty(widget, refresh_type) table.insert(refreshes, { widget = widget, type = refresh_type }) end
function UIManager:show(widget)
    table.insert(shown, widget)
    if widget.onShow then widget:onShow() end
end
local broadcasts = {}
function UIManager:broadcastEvent(event) table.insert(broadcasts, event.name) end
local real_sleeps = 0
function UIManager:suspend() real_sleeps = real_sleeps + 1 end
function UIManager:close(widget)
    table.insert(closed, widget)
    if widget.onCloseWidget then widget:onCloseWidget() end
end

local reader_settings = {}
G_reader_settings = {
    nilOrTrue = function(_, key) return reader_settings[key] == nil or reader_settings[key] == true end,
    flipNilOrTrue = function(_, key)
        if reader_settings[key] == nil or reader_settings[key] == true then reader_settings[key] = false
        else reader_settings[key] = nil end
    end,
}

local connected = true
local battery = { level = 90, charging = true }
local Device = {
    model = "KindlePaperWhite4",
    screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
        scaleBySize = function(_, n) return n end,
    },
}
function Device:isKindle() return true end
function Device:getPowerDevice()
    return {
        getCapacity = function() return battery.level end,
        isCharging = function() return battery.charging end,
    }
end

-- Stands in for SimpleUI's module registry.
local home_modules = {}
local HomeRegistry = { register = function(mod) home_modules[mod.id] = mod end }

local stubs = {
    ["modules/moduleregistry"] = HomeRegistry,
    ["ui/widget/confirmbox"] = class(),
    ["ui/event"] = { new = function(_, name) return { name = name } end },
    datastorage = { getSettingsDir = function() return settings_dir end },
    device = Device,
    pluginshare = PluginShare,
    dispatcher = Dispatcher,
    logger = { warn = function() end },
    gettext = function(text) return text end,
    ["ui/uimanager"] = UIManager,
    ["ui/network/manager"] = { isConnected = function() return connected end },
    ["ui/font"] = { getFace = function(_, _, size) return { size = size or 20 } end },
    ["ui/geometry"] = class(),
    ["ui/gesturerange"] = class(),
    -- Strict, like a real name check: a wrong colour once left the page transparent.
    ["ffi/blitbuffer"] = setmetatable({ COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_LIGHT_GRAY = 204, COLOR_DARK_GRAY = 136 }, {
        __index = function(_, key) error("unknown Blitbuffer field: " .. key) end,
    }),
    ["ui/widget/infomessage"] = class(),
    ["ui/widget/container/widgetcontainer"] = class(),
    ["ui/widget/container/inputcontainer"] = class(),
    ["ui/widget/container/framecontainer"] = class(),
    ["ui/widget/textboxwidget"] = class(),
    ["ui/widget/verticalgroup"] = class(),
    ["ui/widget/verticalspan"] = class(),
    ["ui/widget/button"] = class(),
    ["ui/widget/horizontalspan"] = class(),
    ["ui/widget/linewidget"] = class(),
    ["ui/widget/titlebar"] = class(),
    ["ui/widget/scrollhtmlwidget"] = class(),
    ["libs/libkoreader-lfs"] = {
        attributes = function(path) return io.open(path .. "/.") and "directory" or nil end,
        -- os.execute is replaced by a recorder in this file, so call the real one.
        mkdir = function(path) real_execute("mkdir -p '" .. path .. "'") end,
    },
    ["ui/widget/container/leftcontainer"] = class(),
    ["ui/widget/overlapgroup"] = class(),
    ["ui/widget/textwidget"] = class(),
    ["ui/widget/horizontalgroup"] = class(),
    ["ui/widget/container/centercontainer"] = class(),
}
for name, stub in pairs(stubs) do
    package.preload[name] = function() return stub end
end

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

local function marker() return settings_dir .. "/dash_keepawake.marker" end
local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
end
local function ran(pattern)
    for _, command in ipairs(commands) do
        if command:find(pattern) then return true end
    end
    return false
end
local function runScheduled()
    local due = {}
    for fn in pairs(scheduled) do due[#due + 1] = fn end
    scheduled = {}
    for _, fn in ipairs(due) do fn() end
end
local function httpGet(path)
    local client = assert(socket.connect("127.0.0.1", 8787))
    client:settimeout(0)
    client:send("GET " .. path .. " HTTP/1.1\r\n\r\n")
    local received, deadline = "", socket.gettime() + 2
    while socket.gettime() < deadline do
        runScheduled()
        local data, err, partial = client:receive(4096)
        received = received .. (data or partial or "")
        if err == "closed" then return received end
        socket.sleep(0.002)
    end
    error("no response: " .. received)
end

local function lastShown() return shown[#shown] end

-- The newest dashboard, which may be under a reader view.
local function dashboard()
    for i = #shown, 1, -1 do
        if shown[i].get_status then return shown[i] end
    end
end

-- A marker from a pretend crash must exist before the plugin loads.
io.open(marker(), "w"):close()
-- So must a restart request left over from before this start.
local restart_request = settings_dir .. "/dash_restart_request"
io.open(restart_request, "w"):close()
local Dash = dofile("plugin/dash.koplugin/main.lua")

test("startup clears a marker left by a crash", function()
    assert(not exists(marker()), "marker still present")
    assert(ran("preventScreenSaver 0"), "screensaver block not reset")
end)

test("startup clears an old restart request", function()
    assert(not exists(restart_request), "old request still present")
end)

local plugin = Dash:new{ ui = { menu = { registerToMainMenu = function() end } } }
local items = {}
plugin:addToMainMenu(items)

local open_item = items.dash.sub_item_table[1]
local sleep_item = items.dash.sub_item_table[2]

test("adds a menu entry", function()
    assert(items.dash.text and open_item.callback, "menu item missing")
end)

test("Audi auto-switch is on in the menu until turned off", function()
    local item = items.dash.sub_item_table[3]
    assert(item, "no Audi menu item")
    assert(item.text == "Open Audi mode for new items", item.text)
    assert(item.checked_func(), "auto-switch should default on")
    item.callback()
    assert(not item.checked_func(), "callback didn't turn it off")
    item.callback()
    assert(item.checked_func(), "callback didn't turn it back on")
end)

test("registers an Open Dash action for gestures", function()
    local action = registered_actions.dash_open
    assert(action, "action not registered")
    assert(action.event == "OpenDash" and action.general == true, "wrong action settings")
    assert(type(plugin["on" .. action.event]) == "function", "no handler for the event")
end)

test("opening applies every keep-awake setting", function()
    commands = {}
    open_item.callback()
    assert(dashboard(), "dashboard not shown")
    assert(PluginShare.pause_auto_suspend == true, "auto-suspend not paused")
    assert(PluginShare.keepalive == true, "keepalive not set")
    assert(ran("preventScreenSaver 1"), "screensaver not blocked")
    assert(exists(marker()), "marker missing")
    assert(ran("iptables %-A INPUT"), "firewall not opened")
end)

local function findButton(widget)
    if type(widget) ~= "table" then return nil end
    if widget.text == "Exit" then return widget end
    for _, child in ipairs(widget) do
        local found = findButton(child)
        if found then return found end
    end
    return nil
end

local function holdLock()
    dashboard().lock_button.hold_callback()
    runScheduled()
end

local function tapExit()
    dashboard().exit_button.callback()
end

test("regression: the page has an opaque background filling the screen", function()
    local frame = dashboard()[1]
    assert(frame.background == 255, "background is not white")
    local group = frame[1]
    assert(group.dimen.w == 1072 and group.dimen.h == 1448, "content doesn't fill the screen")
end)

test("the Exit button sits in the bottom right corner", function()
    local button = findButton(dashboard()[1])
    assert(button, "no Exit button")
    local x, y = button.overlap_offset[1], button.overlap_offset[2]
    assert(x + 200 <= 1072 and x > 1072 / 2, "not on the right: " .. x)
    assert(y + 60 <= 1448 and y > 1448 * 0.9, "not at the bottom: " .. y)
end)

test("shows the battery level and updates it each minute", function()
    local dashboard = dashboard()
    assert(dashboard.battery_widget.text == "Battery 90% (charging)", dashboard.battery_widget.text)
    battery.level, battery.charging = 41, false
    dashboard:refresh()
    assert(dashboard.battery_widget.text == "Battery 41%", dashboard.battery_widget.text)
    battery.level, battery.charging = 90, true
end)

test("the drain tile follows charging and records readings each minute", function()
    local dashboard = dashboard()
    dashboard:refresh()
    assert(dashboard.drain_widget.text == "Charging", dashboard.drain_widget.text)
    battery.level, battery.charging = 41, false
    dashboard:refresh()
    assert(dashboard.drain_widget.text == "Drain: measuring…", dashboard.drain_widget.text)
    assert(dashboard.drain_detail_widget.text:find("41%", 1, true), dashboard.drain_detail_widget.text)
    assert(exists(settings_dir .. "/dash_battery.json"), "battery history not saved")
    battery.level, battery.charging = 90, true
    dashboard:refresh()
end)

test("Lock sits left of Exit, the same size, on the bottom row", function()
    local dashboard = dashboard()
    local lock, exit = dashboard.lock_button, dashboard.exit_button
    assert(lock.text == "Lock", "label: " .. tostring(lock.text))
    assert(lock.width == exit.width, "different widths")
    assert(lock.overlap_offset[2] == exit.overlap_offset[2], "not on the same row")
    assert(lock.overlap_offset[1] + 200 <= exit.overlap_offset[1], "Lock overlaps or sits right of Exit")
    assert(exit.width < 1072 * 0.2, "Exit is still large: " .. exit.width)
end)

test("tapping Lock only explains; it doesn't lock", function()
    local dashboard = dashboard()
    dashboard.lock_button.callback()
    assert(not dashboard.locked, "a tap locked it")
    assert(lastShown().text:find("Hold", 1, true), "no hint")
end)

test("holding Lock locks: only the Lock button gets touches", function()
    local dashboard = dashboard()
    holdLock()
    assert(dashboard.locked, "not locked")
    local lock = dashboard.lock_button
    assert(lock.text == "Locked", "button label: " .. tostring(lock.text))
    assert(lastShown().text:find("Hold", 1, true), "no hint shown after locking")

    lock.received = 0
    dashboard.exit_button.received = 0
    dashboard.status_widget.received = 0
    assert(dashboard:handleEvent({ handler = "onGesture" }) == true, "gesture not swallowed")
    assert(lock.received == 1, "the Lock button must still get gestures")
    assert(dashboard.exit_button.received == 0, "a gesture reached Exit")
    assert(dashboard.status_widget.received == 0, "a gesture reached the rest of the dashboard")
end)

test("holding Locked unlocks, and touches reach everything again", function()
    local dashboard = dashboard()
    holdLock()
    assert(not dashboard.locked, "still locked")
    assert(dashboard.lock_button.text == "Lock", "button label: " .. tostring(dashboard.lock_button.text))
    dashboard.status_widget.received = 0
    dashboard:handleEvent({ handler = "onGesture" })
    assert(dashboard.status_widget.received == 1, "gestures still blocked after unlocking")
end)

test("opening twice doesn't create a second dashboard", function()
    local count = #shown
    open_item.callback()
    assert(#shown == count, "second dashboard shown")
end)

test("/ping works without a token", function()
    local response = httpGet("/ping")
    assert(response:find("200 OK", 1, true), response)
end)

local function httpRequest(method, path, token, body)
    local client = assert(socket.connect("127.0.0.1", 8787))
    client:settimeout(0)
    body = body or ""
    client:send(string.format("%s %s HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s",
        method, path, token, #body, body))
    local received, deadline = "", socket.gettime() + 2
    while socket.gettime() < deadline do
        runScheduled()
        local data, err, partial = client:receive(4096)
        received = received .. (data or partial or "")
        if err == "closed" then return received end
        socket.sleep(0.002)
    end
    error("no response: " .. received)
end

local function readToken()
    local file = assert(io.open(settings_dir .. "/dash_config.json", "r"))
    local token = require("json").decode(file:read("*a")).token
    file:close()
    return token
end

test("creates a 32 character hex token", function()
    assert(#readToken() == 32 and readToken():match("^%x+$"), "bad token")
end)

test("unknown paths need a token, then return 404", function()
    assert(httpGet("/nope"):find("401", 1, true), "expected 401")
    assert(httpRequest("GET", "/nope", readToken()):find("404", 1, true), "expected 404")
end)

test("a wrong token is rejected", function()
    assert(httpRequest("GET", "/v1/state", "wrong"):find("401", 1, true), "expected 401")
end)

test("a message sent over HTTP reaches the dashboard's inbox", function()
    local response = httpRequest("POST", "/v1/inbox", readToken(), '{"title":"Hello 你好","source":"mac"}')
    assert(response:find("201 Created", 1, true), response)
    assert(dashboard().store:unreadCount() == 1, "message not stored")
end)

local function findWidget(widget, predicate)
    if type(widget) ~= "table" then return nil end
    if predicate(widget) then return widget end
    for _, child in ipairs(widget) do
        local found = findWidget(child, predicate)
        if found then return found end
    end
    return nil
end

local dashboard_widget

test("opening a message shows it fullscreen as rendered Markdown", function()
    dashboard_widget = dashboard()
    local response = httpRequest("POST", "/v1/inbox", readToken(),
        '{"id":"md","title":"Report","source":"ci","body":"# Results\\n\\n<b>raw</b> and **bold**"}')
    local message = dashboard_widget.store:getMessage("md")
    assert(message, "message not stored: " .. response:gsub("\r\n", " "))
    assert(message.preview == "Results <b>raw</b> and bold", tostring(message.preview))
    dashboard_widget:openMessage(message)
    local view = lastShown()
    assert(view ~= dashboard_widget and view.covers_fullscreen, "not a fullscreen view")
    local html = findWidget(view[1], function(w) return w.html_body ~= nil end).html_body
    assert(html:find("<h1>Results</h1>", 1, true), html)
    assert(html:find("&lt;b&gt;raw&lt;/b&gt;", 1, true), "raw HTML not escaped: " .. html)
    local title_bar = findWidget(view[1], function(w) return w.left_icon ~= nil end)
    assert(title_bar.title == "Report" and title_bar.left_icon == "chevron.left", "no header with back button")
    assert(title_bar.subtitle:find("ci", 1, true), "subtitle missing source")
end)

test("back closes the reader and refreshes the screen", function()
    local view = lastShown()
    refreshes = {}
    findWidget(view[1], function(w) return w.left_icon ~= nil end).left_icon_tap_callback()
    assert(closed[#closed] == view, "reader not closed")
    local refreshed = false
    for _, refresh in ipairs(refreshes) do
        if refresh.widget == nil and refresh.type == "full" then refreshed = true end
    end
    assert(refreshed, "screen not refreshed after back")
    assert(dashboard_widget.store:getMessage("md").read_at == nil, "back marked it read")
end)

test("Mark as read in the reader closes it and marks the message", function()
    dashboard_widget:openMessage(dashboard_widget.store:getMessage("md"))
    local view = lastShown()
    findWidget(view[1], function(w) return w.text == "Mark as read" end).callback()
    assert(closed[#closed] == view, "reader not closed")
    assert(dashboard_widget.store:getMessage("md").read_at, "not marked read")
end)

test("marking a message read on the dashboard clears it from unread", function()
    local dashboard = dashboard_widget
    dashboard:markRead(dashboard.store:unreadMessages()[1])
    assert(dashboard.store:unreadCount() == 0, "still unread")
end)

test("Read all asks first, then marks every message read", function()
    local dashboard = dashboard_widget
    httpRequest("POST", "/v1/inbox", readToken(), '{"title":"one"}')
    httpRequest("POST", "/v1/inbox", readToken(), '{"title":"two"}')
    runScheduled()
    local unread = dashboard.store:unreadCount()
    assert(unread >= 2, "setup: " .. unread)
    assert(dashboard.read_all_button, "no Read all button with unread messages")
    dashboard.read_all_button.callback()
    local confirm = lastShown()
    assert(confirm.ok_callback and confirm.text:find(tostring(unread), 1, true), "no confirmation")
    assert(dashboard.store:unreadCount() == unread, "marked before confirming")
    confirm.ok_callback()
    runScheduled()
    assert(dashboard.store:unreadCount() == 0, "still unread")
    assert(dashboard.read_all_button == nil, "Read all still shown with nothing unread")
end)

test("a partial state update reaches the store", function()
    local response = httpRequest("PUT", "/v1/state", readToken(), '{"todo":{"count":3}}')
    assert(response:find('"changed":true', 1, true), response)
    assert(dashboard_widget.store.state.todo.count == 3, "state not updated")
end)

local function findText(widget, text)
    if type(widget) ~= "table" then return nil end
    if widget.text == text then return widget end
    for _, child in ipairs(widget) do
        local found = findText(child, text)
        if found then return found end
    end
    return nil
end

test("usage tiles show every provider, with no data yet", function()
    local dashboard = dashboard()
    for _, title in ipairs({ "Grok", "Claude", "DeepSeek", "xAI API" }) do
        assert(findText(dashboard[1], title), "no tile for " .. title)
    end
    assert(findText(dashboard[1], "No data yet"), "no empty state")
end)

test("usage sent over HTTP shows on its tile", function()
    local dashboard = dashboard()
    dashboard.store:mergeState({ usage = { grok = { used_pct = 17.4, label = "Grok Bot", updated_at = os.time() } } })
    runScheduled()
    assert(findText(dashboard[1], "Grok Bot"), "label not shown")
    assert(findText(dashboard[1], "17%"), "percent not shown")
end)

test("a usage tile going stale rebuilds the screen", function()
    local dashboard = dashboard()
    dashboard.store:mergeState({ usage = { grok = { used_pct = 17.4, updated_at = os.time(), expires_at = os.time() + 3600 } } })
    runScheduled()
    dashboard.store.state.usage.grok.expires_at = os.time() - 1
    refreshes = {}
    dashboard:refresh()
    assert(refreshes[#refreshes].type == "full", "no full refresh: " .. tostring(refreshes[#refreshes].type))
    assert(dashboard.usage_tiles[1].stale, "tile not stale after rebuild")
end)

-- A real VerticalGroup caches its children's positions in getSize, and painting one that
-- gained a child afterwards crashed KOReader.
test("regression: no group gains children after it's measured", function()
    local VerticalGroup = stubs["ui/widget/verticalgroup"]
    local real_get_size = VerticalGroup.getSize
    local measured = {}
    VerticalGroup.getSize = function(self)
        measured[self] = #self
        return { w = 200, h = 20 * #self }
    end
    local dashboard = dashboard()
    -- A taller tile than the rest, so the others get padded.
    dashboard.store:mergeState({ usage = {
        grok = { used_pct = 50, detail = "week", resets_at = os.time() + 3600, updated_at = os.time() },
    } })
    local ok, err = pcall(dashboard.rebuild, dashboard, "partial")
    VerticalGroup.getSize = real_get_size
    assert(ok, err)
    for group, count in pairs(measured) do
        assert(#group == count, string.format("measured with %d children, now has %d", count, #group))
    end
end)

test("the screen shows the ping count", function()
    local status = dashboard().get_status()
    assert(status:find("Pings: 1", 1, true), status)
end)

test("suspend stops the server, resume restarts it", function()
    plugin:onSuspend()
    assert(not socket.connect("127.0.0.1", 8787), "server still listening")
    plugin:onResume()
    assert(httpGet("/ping"):find("200 OK", 1, true), "no response after resume")
end)

test("the gesture action opens the dashboard", function()
    tapExit()
    local count = #shown
    plugin:onOpenDash()
    assert(#shown == count + 1 and dashboard().get_status, "dashboard not opened by the action")
end)

test("Audi sits left of Lock, the same size, on the bottom row", function()
    local dash = dashboard()
    local audi, lock, exit = dash.audi_button, dash.lock_button, dash.exit_button
    assert(audi, "no Audi button")
    assert(audi.text == "Audi", "label: " .. tostring(audi.text))
    assert(audi.width == lock.width and lock.width == exit.width, "different widths")
    assert(audi.overlap_offset[2] == lock.overlap_offset[2], "not on the same row as Lock")
    assert(lock.overlap_offset[2] == exit.overlap_offset[2], "Lock and Exit split rows")
    assert(audi.overlap_offset[1] < lock.overlap_offset[1], "Audi is not left of Lock")
    assert(lock.overlap_offset[1] < exit.overlap_offset[1], "Lock is not left of Exit")
    assert(not audi.preselect, "Audi looks selected on the dashboard")
end)

test("Audi toggles a fullscreen idle view and back to Dash", function()
    local dash = dashboard()
    dash:toggleAudi()
    assert(dash.mode == "audi", "not in Audi mode")
    assert(dash.audi_button.preselect == true, "Audi button not marked selected")
    assert(findText(dash[1], "暂无内容"), "idle text missing")
    assert(not findText(dash[1], "Inbox"), "dashboard inbox still shown")
    dash:toggleAudi()
    assert(dash.mode == "dash", "didn't return to Dash")
    assert(findText(dash[1], "Inbox"), "inbox missing after leaving Audi")
    assert(not dash.audi_button.preselect, "Audi still looks selected")
end)

test("a new Audi entry auto-switches with a full refresh and is not in the inbox", function()
    local dash = dashboard()
    local unread = dash.store:unreadCount()
    refreshes = {}
    local response = httpRequest("POST", "/v1/audi", readToken(),
        '{"id":"audi-test-12","ref":12,"title":"DeepSeek review","source":"DeepSeek","body":"## Summary\\n\\n<script>no</script> and **bold**"}')
    assert(response:find("201 Created", 1, true), response)
    assert(dash.mode == "audi", "didn't enter Audi mode")
    local full = false
    for _, refresh in ipairs(refreshes) do
        if refresh.widget == dash and refresh.type == "full" then full = true end
    end
    assert(full, "new Audi entry didn't request a full refresh")
    assert(findText(dash[1], "DeepSeek review"), "title missing")
    local meta = findWidget(dash[1], function(widget)
        return type(widget.text) == "string" and widget.text:find("#12", 1, true) and widget.text:find("DeepSeek", 1, true)
    end)
    assert(meta, "header missing #ref and source")
    assert(meta.text:find("%d%d:%d%d"), "header missing the time")
    local html_widget = findWidget(dash[1], function(widget) return widget.html_body ~= nil end)
    assert(html_widget, "no Markdown body")
    assert(html_widget.html_body:find("&lt;script&gt;", 1, true), "raw HTML not escaped: " .. html_widget.html_body)
    assert(html_widget.html_body:find("<strong>bold</strong>", 1, true), html_widget.html_body)
    assert(not findText(dash[1], "Mark as read"), "Audi view has a reply button")
    assert(dash.store:unreadCount() == unread, "Audi entry landed in the inbox")
    assert(dash.store:getMessage("audi-test-12") == nil, "Audi id is an inbox message")
    local inbox = httpRequest("GET", "/v1/inbox", readToken())
    assert(not inbox:find("DeepSeek review", 1, true), inbox)
    assert(dash.audi_index == 1, "not showing the only entry")
    assert(findText(dash[1], "1/1"), "position missing")
end)

test("an open inbox reader closes when Audi auto-switches", function()
    local dash = dashboard()
    dash:toggleAudi()
    assert(dash.mode == "dash", "setup")
    local message = dash.store.messages[1]
    assert(message, "need an inbox message")
    dash:openMessage(message)
    local view = lastShown()
    assert(view ~= dash, "reader didn't open")
    httpRequest("POST", "/v1/audi", readToken(),
        '{"id":"audi-test-12","title":"DeepSeek review","body":"Updated body"}')
    assert(closed[#closed] == view, "inbox reader stayed open")
    assert(dash.mode == "audi", "didn't return to Audi")
    assert(dash.audi:get("audi-test-12").ref == 12, "update didn't keep ref")
end)

test("locked Audi mode scrolls the current entry only", function()
    local dash = dashboard()
    httpRequest("POST", "/v1/audi", readToken(),
        '{"id":"audi-older","ref":11,"title":"Older note","source":"Audi","body":"Previous"}')
    -- The new row is older in time but appended, so it is last. Put the view on it.
    assert(dash.mode == "audi", "not in Audi")
    assert(#dash.audi.entries >= 2, "need two entries")
    assert(dash.audi_index == #dash.audi.entries, "new entry wasn't shown")
    local index = dash.audi_index
    assert(dash.audi_scroll, "no scroller")
    holdLock()
    assert(dash.locked, "not locked")
    dash.audi_scroll.received = 0
    dash.exit_button.received = 0
    dash.audi_button.received = 0
    dash.lock_button.received = 0
    if dash.audi_prev then dash.audi_prev.received = 0 end
    assert(dash:handleEvent({ handler = "onGesture" }) == true, "gesture not swallowed")
    assert(dash.audi_scroll.received == 1, "the entry didn't get the scroll gesture")
    assert(dash.lock_button.received == 1, "Lock didn't get the gesture")
    assert(dash.exit_button.received == 0, "Exit got a gesture while locked")
    assert(dash.audi_button.received == 0, "Audi got a gesture while locked")
    if dash.audi_prev then
        assert(dash.audi_prev.received == 0, "history button got a gesture while locked")
    end
    dash:pageAudi(-1)
    assert(dash.audi_index == index, "history paging worked while locked")
    dash:toggleAudi()
    assert(dash.mode == "audi", "locked Audi returned to Dash")
    holdLock()
    assert(not dash.locked, "still locked")
    dash:pageAudi(-1)
    assert(dash.audi_index == index - 1, "paging didn't work after unlock")
    dash:toggleAudi()
    assert(dash.mode == "dash", "didn't leave Audi")
end)

test("auto-switch off keeps Dash up and badges the Audi button", function()
    local dash = dashboard()
    assert(dash.mode == "dash", "setup")
    reader_settings.dash_audi_auto_switch = false
    dash.minutes_since_full_refresh = 0
    refreshes = {}
    httpRequest("POST", "/v1/audi", readToken(),
        '{"id":"audi-quiet","ref":14,"title":"Quiet note","source":"Audi","body":"Later"}')
    assert(dash.mode == "dash", "auto-switch off still entered Audi")
    assert(dash.audi_button.text == "Audi·1", "badge: " .. tostring(dash.audi_button.text))
    local switched = false
    for _, refresh in ipairs(refreshes) do
        if refresh.widget == dash and refresh.type == "full" then switched = true end
    end
    assert(not switched, "auto-switch off still full-refreshed into Audi")
    reader_settings.dash_audi_auto_switch = nil
end)

test("resume opens an unshown Audi entry when auto-switch is on", function()
    local dash = dashboard()
    reader_settings.dash_audi_auto_switch = false
    httpRequest("POST", "/v1/audi", readToken(),
        '{"id":"audi-while-away","ref":15,"title":"While away","body":"Pending"}')
    assert(dash.mode == "dash", "setup")
    assert(dash.audi.pending_show == true, "entry was already shown")
    reader_settings.dash_audi_auto_switch = nil
    refreshes = {}
    plugin:onSuspend()
    plugin:onResume()
    assert(dash.mode == "audi", "resume didn't open Audi")
    assert(dash.audi.pending_show == false, "still pending after it was shown")
    assert(findText(dash[1], "While away"), "resumed entry not shown")
    local full = false
    for _, refresh in ipairs(refreshes) do
        if refresh.widget == dash and refresh.type == "full" then full = true end
    end
    assert(full, "resume didn't full-refresh Audi")
    dash:toggleAudi()
    assert(dash.mode == "dash", "cleanup")
end)

test("clear keeps Audi history and shows the idle line", function()
    local dash = dashboard()
    dash:toggleAudi()
    local kept = #dash.audi.entries
    assert(kept >= 1, "setup")
    httpRequest("POST", "/v1/audi/clear", readToken(), "")
    assert(dash.mode == "audi", "clear left Audi mode")
    assert(#dash.audi.entries == kept, "clear deleted history")
    assert(findText(dash[1], "暂无内容"), "idle text missing after clear")
    assert(dash.audi:current() == nil, "still showing an entry")
    dash:toggleAudi()
end)

test("tapping Exit saves data and undoes everything", function()
    commands = {}
    refreshes = {}
    tapExit()
    local refreshed = false
    for _, refresh in ipairs(refreshes) do
        if refresh.widget == nil and refresh.type == "full" then refreshed = true end
    end
    assert(refreshed, "regression: closing must refresh the whole display")
    local saved = io.open(settings_dir .. "/dash_data.json", "r")
    assert(saved, "data was not saved")
    assert(saved:read("*a"):find('"count":3', 1, true), "state missing from saved file")
    saved:close()
    assert(closed[#closed], "dashboard not closed")
    assert(PluginShare.pause_auto_suspend == nil, "auto-suspend still paused")
    assert(PluginShare.keepalive == nil, "keepalive still set")
    assert(ran("preventScreenSaver 0"), "screensaver still blocked")
    assert(ran("iptables %-D INPUT"), "firewall still open")
    assert(not exists(marker()), "marker still present")
    assert(not socket.connect("127.0.0.1", 8787), "server still listening")
end)

test("closing leaves an existing KeepAlive plugin in charge", function()
    PluginShare.keepalive = true
    open_item.callback()
    commands = {}
    tapExit()
    assert(PluginShare.keepalive == true, "keepalive was cleared")
    assert(not ran("preventScreenSaver 0"), "screensaver block was removed")
    PluginShare.keepalive = nil
end)

test("exit releases keep-awake", function()
    open_item.callback()
    plugin:onExit()
    assert(PluginShare.pause_auto_suspend == nil, "auto-suspend still paused")
    assert(not exists(marker()), "marker still present")
end)

test("sleep opens Dash instead, while the setting is on", function()
    tapExit() -- the previous test leaves it open
    local count, sleeps = #shown, real_sleeps
    UIManager:suspend()
    assert(#shown == count + 1 and dashboard().get_status, "dashboard not opened")
    assert(real_sleeps == sleeps, "slept anyway")
    assert(PluginShare.pause_auto_suspend == true, "keep-awake not applied")
end)

test("sleeping with Dash open sleeps for real", function()
    local sleeps = real_sleeps
    UIManager:suspend()
    assert(real_sleeps == sleeps + 1, "didn't sleep")
    tapExit()
end)

test("low battery on battery power sleeps for real; charging still opens Dash", function()
    local count, sleeps = #shown, real_sleeps
    battery.level, battery.charging = 19, false
    UIManager:suspend()
    assert(real_sleeps == sleeps + 1 and #shown == count, "didn't sleep at 19%")
    battery.charging = true
    UIManager:suspend()
    assert(#shown == count + 1, "didn't open Dash while charging")
    tapExit()
    battery.level = 90
end)

test("turning the setting off restores normal sleep", function()
    assert(sleep_item.checked_func() == true, "should default to on")
    sleep_item.callback()
    assert(sleep_item.checked_func() == false, "toggle didn't turn it off")
    local count, sleeps = #shown, real_sleeps
    UIManager:suspend()
    assert(real_sleeps == sleeps + 1 and #shown == count, "didn't sleep with the setting off")
    sleep_item.callback()
end)

test("adds a Dash module to SimpleUI's home screen", function()
    local mod = home_modules.dash
    assert(mod, "module not registered")
    assert(mod.default_on == false and mod.enabled_key, "should be opt-in")
    tapExit()
    dashboard().store:mergeState({ weather = { summary = "Cloudy 12°" } })
    local ctx = { pfx = "simpleui_hs_" }
    local widget = mod.build(800, ctx)
    local texts = {}
    local function collect(w)
        if type(w) ~= "table" then return end
        if w.text then table.insert(texts, w.text) end
        for _, child in ipairs(w) do collect(child) end
    end
    collect(widget)
    local all = table.concat(texts, "\n")
    assert(#texts == 4, "expected 4 lines: " .. all)
    assert(texts[1] == "Cloudy 12°", all)
    assert(texts[2]:find("Todo: 3", 1, true) and texts[2]:find("0 unread", 1, true), all)
    assert(widget.dimen.h == mod.getHeight(ctx), "height doesn't match getHeight")

    local count = #shown
    widget:onTapDash()
    assert(#shown == count + 1 and dashboard().get_status, "tap didn't open Dash")
    tapExit()
end)

test("a restart request closes Dash and restarts KOReader once", function()
    open_item.callback()
    local open = dashboard()
    broadcasts = {}
    runScheduled()
    assert(#broadcasts == 0, "restarted with no request")
    io.open(restart_request, "w"):close()
    runScheduled()
    assert(broadcasts[1] == "Restart" and #broadcasts == 1, "no Restart event")
    assert(not exists(restart_request), "request not removed")
    assert(closed[#closed] == open, "Dash not closed before restarting")
    assert(exists(settings_dir .. "/dash_open_request"), "no request to reopen Dash after the restart")
    runScheduled()
    assert(#broadcasts == 1, "restarted twice")
end)

test("an open request at startup opens Dash once, as after a deploy", function()
    local request = settings_dir .. "/dash_open_request"
    io.open(request, "w"):close()
    -- A fresh start: KOReader loads the plugin again after restarting.
    local Restarted = dofile("plugin/dash.koplugin/main.lua")
    local before = #shown
    Restarted:new{ ui = { menu = { registerToMainMenu = function() end } } }
    assert(not exists(request), "request not removed")
    runScheduled()
    assert(#shown == before + 1 and shown[#shown].get_status, "Dash not opened")
    Restarted:new{ ui = { menu = { registerToMainMenu = function() end } } }
    runScheduled()
    assert(#shown == before + 1, "opened again by a second plugin instance")
    shown[#shown].on_close()
end)

os.execute = real_execute
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

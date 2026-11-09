-- A module for SimpleUI's home screen: a summary of the dashboard that opens Dash when tapped.
-- SimpleUI is optional; main.lua registers this only when its module registry is available.
-- Shows what the dashboard's server last received; nothing updates while Dash is closed.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local Screen = Device.screen

-- { font size, bold } per line, top to bottom. The height is fixed so getHeight
-- matches build without measuring text.
local LINES = {
    { 24, true },  -- weather
    { 18, false }, -- todo and unread count
    { 18, false }, -- top unread title, in inbox order
    { 16, false }, -- battery drain
}
local LINE_SPACING = 1.45

local DashHome = {}

local function text(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    if type(value) == "number" then
        return tostring(value)
    end
    return nil
end

local function scaleFor(id, ctx)
    local ok, Config = pcall(require, "infra/sui_config")
    local scale = ok and type(Config.getModuleScale) == "function" and Config.getModuleScale(id, ctx.pfx) or 1
    return scale * (ctx.landscape_factor or 1)
end

local function lineHeight(size, scale)
    return math.ceil(Screen:scaleBySize(size * scale) * LINE_SPACING)
end

-- The text of each line, from the dashboard's data.
function DashHome.lines(data)
    local state = data.store.state
    local weather = type(state.weather) == "table" and state.weather or {}
    local expired = type(weather.expires_at) == "number" and os.time() >= weather.expires_at
    local todo = type(state.todo) == "table" and state.todo or {}
    local unread = data.store:unreadMessages()

    local counts = string.format(_("Todo: %s  ·  Inbox: %d unread"), text(todo.count) or "—", #unread)
    local top = unread[1] and ("• " .. (text(unread[1].title) or _("(untitled)"))) or _("No new messages")
    return {
        not expired and text(weather.summary) or _("Weather: —"),
        counts,
        top,
        data.drain,
    }
end

-- opts:
--   get_data: function returning { store = dash_store, drain = string }, or nil when unavailable
--   open: function that opens the full dashboard
function DashHome.new(opts)
    local M = {
        id = "dash",
        name = _("Dash"),
        label = _("Dash"),
        category = "extras",
        enabled_key = "dash_enabled",
        default_on = false,
    }

    function M.getHeight(ctx)
        local scale = scaleFor(M.id, ctx)
        local height = 0
        for _, line in ipairs(LINES) do
            height = height + lineHeight(line[1], scale)
        end
        return height
    end

    function M.build(width, ctx)
        local data = opts.get_data()
        if not data then
            return nil
        end
        local scale = scaleFor(M.id, ctx)
        local color = ctx.ink and ctx.ink.blk or Blitbuffer.COLOR_BLACK
        local group = VerticalGroup:new{ align = "left" }
        for index, value in ipairs(DashHome.lines(data)) do
            local size, bold = LINES[index][1], LINES[index][2]
            table.insert(group, LeftContainer:new{
                dimen = Geom:new{ w = width, h = lineHeight(size, scale) },
                TextWidget:new{
                    text = value,
                    face = Font:getFace("infofont", math.floor(size * scale + 0.5)),
                    bold = bold,
                    fgcolor = color,
                    max_width = width,
                },
            })
        end

        local tappable = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = width, h = M.getHeight(ctx) },
            group,
        }
        tappable.ges_events = {
            TapDash = {
                GestureRange:new{ ges = "tap", range = function() return tappable.dimen end },
            },
        }
        function tappable:onTapDash()
            opts.open()
            return true
        end
        return tappable
    end

    return M
end

return DashHome

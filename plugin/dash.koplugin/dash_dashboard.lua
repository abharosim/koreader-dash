-- Fullscreen dashboard: clock, calendar, state values, inbox, diagnostics and an Exit button.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local DashTime = require("dash_time")
local MessageView = require("dash_message_view")
local Screen = Device.screen

local FULL_REFRESH_EVERY_MINUTES = 60
local WEEKDAY_LETTERS = { "S", "M", "T", "W", "T", "F", "S" }

local function dateText()
    local now = DashTime.fields()
    return string.format("%s, %s %d", DashTime.format("%A"), DashTime.format("%B"), now.day)
end

local function batteryText()
    local powerd = Device:getPowerDevice()
    local text = string.format("Battery %d%%", powerd:getCapacity())
    if powerd:isCharging() then
        text = text .. " (charging)"
    end
    return text
end

-- Network data can hold any JSON type, so only plain values are ever displayed.
local function displayValue(value)
    local kind = type(value)
    if kind == "string" and value ~= "" then
        return (value:gsub("%s+", " "))
    end
    if kind == "number" then
        return tostring(value)
    end
    return nil
end

local function messageTime(message)
    local received = DashTime.fields(message.received_at)
    local now = DashTime.fields()
    if received.day == now.day and received.month == now.month and received.year == now.year then
        return DashTime.format("%H:%M", message.received_at)
    end
    return DashTime.format("%b %d, %H:%M", message.received_at)
end

local function calendarCell(text, cell, options)
    options = options or {}
    return FrameContainer:new{
        background = options.inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = cell.w, h = cell.h },
            TextWidget:new{
                text = text,
                face = Font:getFace("infofont", 17),
                bold = options.bold,
                fgcolor = options.inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            },
        },
    }
end

local function buildCalendar(now, cell)
    local rows = VerticalGroup:new{
        TextWidget:new{
            text = DashTime.format("%B %Y"),
            face = Font:getFace("infofont", 18),
            bold = true,
        },
        VerticalSpan:new{ width = math.floor(cell.h * 0.2) },
    }

    local header = HorizontalGroup:new{}
    for _, letter in ipairs(WEEKDAY_LETTERS) do
        table.insert(header, calendarCell(letter, cell, { bold = true }))
    end
    table.insert(rows, header)

    for _, week in ipairs(DashTime.monthWeeks(now.year, now.month)) do
        local row = HorizontalGroup:new{}
        for _, day in ipairs(week) do
            table.insert(row, calendarCell(day and tostring(day) or "", cell, {
                inverted = day == now.day,
                bold = day == now.day,
            }))
        end
        table.insert(rows, row)
    end
    return rows
end

-- One inbox line. A tap opens the message; the Read button is handled first by its own widget.
local InboxRow = InputContainer:extend{
    width = nil,
    height = nil,
    message = nil,
    on_open = nil,
    on_read = nil,
    show_parent = nil,
}

function InboxRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.TapRow = {
        GestureRange:new{
            ges = "tap",
            range = function() return self.dimen end,
        },
    }

    local read_button = Button:new{
        text = _("Read"),
        text_font_size = 20,
        width = math.floor(self.width * 0.17),
        show_parent = self.show_parent,
        callback = function() self.on_read(self.message) end,
    }
    local text_width = self.width - read_button:getSize().w - Screen:scaleBySize(8)
    local is_high = self.message.priority == "high"

    local meta = messageTime(self.message)
    local source = displayValue(self.message.source)
    if source then
        meta = source .. "  ·  " .. meta
    end
    if is_high then
        meta = "! " .. meta
    end

    local lines = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = displayValue(self.message.title) or "",
            face = Font:getFace("infofont", 21),
            bold = is_high,
            max_width = text_width,
        },
    }
    local preview = displayValue(self.message.preview)
    if preview then
        local preview_face = Font:getFace("infofont", 16)
        table.insert(lines, TextBoxWidget:new{
            text = preview,
            face = preview_face,
            width = text_width,
            height = 2 * math.ceil(preview_face.size * 1.3),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        })
    end
    table.insert(lines, TextWidget:new{
        text = meta,
        face = Font:getFace("infofont", 14),
        max_width = text_width,
    })

    self[1] = HorizontalGroup:new{
        LeftContainer:new{
            dimen = Geom:new{ w = text_width, h = self.height },
            lines,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        read_button,
    }
end

function InboxRow:onTapRow()
    self.on_open(self.message)
    return true
end

local Dashboard = InputContainer:extend{
    covers_fullscreen = true,
    store = nil,      -- dash_store instance
    get_status = nil, -- function returning the diagnostics text
    get_drain = nil,  -- function returning the battery tile's headline and detail
    on_minute = nil,  -- function called on each minute boundary
    on_close = nil,   -- function called when the user taps Exit
    locked = false,   -- while locked, taps do nothing; holding Exit toggles the lock
    on_lock_change = nil, -- function called with the new lock state
}

function Dashboard:init()
    self.minutes_since_full_refresh = 0
    self.page = 1
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.tick = function()
        self:refresh()
        UIManager:scheduleIn(60 - math.min(tonumber(os.date("%S")), 59), self.tick)
    end
    self.rebuild_task = function()
        self.rebuild_scheduled = false
        self:rebuild("partial")
    end
    self:build()
end

function Dashboard:weatherExpired()
    local weather = self.store.state.weather
    return type(weather) == "table"
        and type(weather.expires_at) == "number"
        and os.time() >= weather.expires_at
end

function Dashboard:buildValues(width)
    local state = self.store.state
    local weather = type(state.weather) == "table" and state.weather or {}
    local todo = type(state.todo) == "table" and state.todo or {}
    local expired = self:weatherExpired()
    self.shown_weather_expired = expired
    self:buildDrain(width)

    return VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = expired and "—" or displayValue(weather.summary) or "—",
            face = Font:getFace("infofont", 24),
            max_width = width,
        },
        TextWidget:new{
            text = not expired and displayValue(weather.detail) or " ",
            face = Font:getFace("infofont", 16),
            max_width = width,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        TextWidget:new{
            text = string.format("Todo: %s", displayValue(todo.count) or "—"),
            face = Font:getFace("infofont", 24),
            max_width = width,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        self.drain_widget,
        self.drain_detail_widget,
    }
end

function Dashboard:buildDrain(width)
    local headline, detail = self.get_drain()
    self.drain_widget = TextWidget:new{
        text = headline,
        face = Font:getFace("infofont", 24),
        max_width = width,
    }
    self.drain_detail_widget = TextWidget:new{
        text = detail,
        face = Font:getFace("infofont", 16),
        max_width = width,
    }
end

function Dashboard:buildPager(page_count)
    if page_count <= 1 then
        return nil
    end
    local function pageButton(label, target)
        return Button:new{
            text = label,
            text_font_size = 18,
            width = math.floor(self.dimen.w * 0.1),
            enabled = target >= 1 and target <= page_count,
            show_parent = self,
            callback = function()
                self.page = target
                self:scheduleRebuild(0.05)
            end,
        }
    end
    return HorizontalGroup:new{
        pageButton("<", self.page - 1),
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(self.dimen.w * 0.12), h = Screen:scaleBySize(30) },
            TextWidget:new{
                text = string.format("%d/%d", self.page, page_count),
                face = Font:getFace("infofont", 16),
            },
        },
        pageButton(">", self.page + 1),
    }
end

function Dashboard:buildInbox(width, available_height)
    local unread = self.store:unreadMessages()
    local row_height = math.floor(self.dimen.h * 0.12)
    local title_height = Screen:scaleBySize(36)
    local per_page = math.max(1, math.floor((available_height - title_height) / (row_height + 1)))
    local page_count = math.max(1, math.ceil(#unread / per_page))
    self.page = math.max(1, math.min(self.page, page_count))

    local title = #unread > 0 and string.format(_("Inbox (%d unread)"), #unread) or _("Inbox")
    local pager = self:buildPager(page_count)
    if pager then
        pager.overlap_align = "right"
    end
    local inbox = VerticalGroup:new{
        align = "left",
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = title_height },
            allow_mirroring = false,
            TextWidget:new{ text = title, face = Font:getFace("infofont", 22), bold = true },
            pager,
        },
    }

    if #unread == 0 then
        table.insert(inbox, VerticalSpan:new{ width = Screen:scaleBySize(12) })
        table.insert(inbox, TextWidget:new{
            text = _("No new messages"),
            face = Font:getFace("infofont", 20),
        })
        return inbox
    end

    local first = (self.page - 1) * per_page + 1
    for index = first, math.min(first + per_page - 1, #unread) do
        table.insert(inbox, LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{ w = width, h = 1 },
        })
        table.insert(inbox, InboxRow:new{
            width = width,
            height = row_height,
            message = unread[index],
            show_parent = self,
            on_open = function(message) self:openMessage(message) end,
            on_read = function(message) self:markRead(message) end,
        })
    end
    return inbox
end

function Dashboard:build()
    local width, height = self.dimen.w, self.dimen.h
    local margin = Screen:scaleBySize(16)
    local content_width = width - margin * 2
    local now = DashTime.fields()
    self.shown_day = now.day

    local cell_width = math.floor(math.min(width, height) * 0.062)
    local cell = { w = cell_width, h = math.floor(cell_width * 0.78) }
    local calendar = buildCalendar(now, cell)
    local left_width = content_width - calendar:getSize().w - margin

    self.time_widget = TextBoxWidget:new{
        text = DashTime.format("%H:%M"),
        face = Font:getFace("tfont", 92),
        width = left_width,
        bold = true,
    }
    self.battery_widget = TextBoxWidget:new{
        text = batteryText(),
        face = Font:getFace("infofont", 17),
        width = left_width,
    }

    local header = HorizontalGroup:new{
        align = "top",
        VerticalGroup:new{
            align = "left",
            self.battery_widget,
            self.time_widget,
            TextBoxWidget:new{
                text = dateText(),
                face = Font:getFace("infofont", 21),
                width = left_width,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            self:buildValues(left_width),
        },
        HorizontalSpan:new{ width = margin },
        calendar,
    }

    local exit_button = Button:new{
        text = self.locked and _("Locked") or _("Exit"),
        text_font_size = 26,
        width = math.floor(width * 0.24),
        padding_v = Screen:scaleBySize(10),
        show_parent = self,
        callback = function()
            if self.locked then
                self:showLockHint(_("Locked. Hold the button to unlock."))
            elseif self.on_close then
                self.on_close()
            end
        end,
        hold_callback = function() self:setLocked(not self.locked) end,
    }
    self.exit_button = exit_button
    local exit_size = exit_button:getSize()
    exit_button.overlap_offset = { width - exit_size.w - margin, height - exit_size.h - margin }

    self.status_widget = TextBoxWidget:new{
        text = self.get_status(),
        face = Font:getFace("infofont", 16),
        width = width - exit_size.w - margin * 3,
        height = exit_size.h,
    }
    self.status_widget.overlap_offset = { margin, height - exit_size.h - margin }

    local gap = Screen:scaleBySize(12)
    local top_height = margin + header:getSize().h + gap * 2 + 2
    local inbox_height = height - top_height - exit_size.h - margin - gap

    local main = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = margin },
        header,
        VerticalSpan:new{ width = gap },
        LineWidget:new{ dimen = Geom:new{ w = content_width, h = 2 } },
        VerticalSpan:new{ width = gap },
        self:buildInbox(content_width, inbox_height),
    }
    main.overlap_offset = { margin, 0 }

    -- The opaque background is what hides the screens underneath.
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = height },
            allow_mirroring = false,
            main,
            self.status_widget,
            exit_button,
        },
    }
end

function Dashboard:rebuild(refresh_type)
    self[1]:free()
    self:build()
    UIManager:setDirty(self, refresh_type)
end

-- Groups bursts of changes, and leaves any button mid-tap intact while it finishes.
function Dashboard:scheduleRebuild(delay)
    if self.rebuild_scheduled then
        return
    end
    self.rebuild_scheduled = true
    UIManager:scheduleIn(delay or 1, self.rebuild_task)
end

function Dashboard:showLockHint(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

function Dashboard:setLocked(locked)
    self.locked = locked
    if self.on_lock_change then
        self.on_lock_change(locked)
    end
    self:showLockHint(locked and _("Locked. Hold the button to unlock.") or _("Unlocked"))
    self:scheduleRebuild(0.05)
end

-- While locked, the Exit button is the only thing that responds to touch.
function Dashboard:handleEvent(event)
    if self.locked and event.handler == "onGesture" then
        if self.exit_button then
            self.exit_button:handleEvent(event)
        end
        return true
    end
    return InputContainer.handleEvent(self, event)
end

function Dashboard:markRead(message)
    self.store:setRead(message.id, true)
    self:scheduleRebuild(0.05)
end

function Dashboard:openMessage(message)
    local subtitle = messageTime(message)
    local source = displayValue(message.source)
    if source then
        subtitle = source .. "  ·  " .. subtitle
    end
    UIManager:show(MessageView:new{
        message = message,
        body = self.store:getBody(message),
        subtitle = subtitle,
        on_mark_read = function(read_message) self:markRead(read_message) end,
    })
end

function Dashboard:refresh()
    -- Runs first, so readings it records show up in this refresh.
    if self.on_minute then
        self.on_minute()
    end
    local needs_rebuild = DashTime.fields().day ~= self.shown_day
        or self:weatherExpired() ~= self.shown_weather_expired
    if needs_rebuild then
        self[1]:free()
        self:build()
    else
        self.time_widget:setText(DashTime.format("%H:%M"))
        self.status_widget:setText(self.get_status())
        self.battery_widget:setText(batteryText())
        local headline, detail = self.get_drain()
        self.drain_widget:setText(headline)
        self.drain_detail_widget:setText(detail)
    end

    self.minutes_since_full_refresh = self.minutes_since_full_refresh + 1
    if needs_rebuild or self.minutes_since_full_refresh >= FULL_REFRESH_EVERY_MINUTES then
        self.minutes_since_full_refresh = 0
        UIManager:setDirty(self, "full")
    else
        UIManager:setDirty(self, "ui")
    end
end

function Dashboard:startClock()
    UIManager:unschedule(self.tick)
    self.tick()
end

function Dashboard:stopClock()
    UIManager:unschedule(self.tick)
    UIManager:unschedule(self.rebuild_task)
    self.rebuild_scheduled = false
end

function Dashboard:onShow()
    UIManager:setDirty(self, "full")
    self:startClock()
    return true
end

function Dashboard:onCloseWidget()
    self:stopClock()
    -- UIManager:close repaints the screens underneath but doesn't refresh the display,
    -- so without this the dashboard stays visible after Exit.
    UIManager:setDirty(nil, "full")
end

return Dashboard

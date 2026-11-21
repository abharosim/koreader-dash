-- Fullscreen message reader: a header with a back button, the Markdown body, and Mark as read.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Markdown = require("dash_markdown")
local Screen = Device.screen

local MessageView = InputContainer:extend{
    covers_fullscreen = true,
    message = nil,      -- the message's index entry
    body = nil,         -- its Markdown text
    subtitle = nil,     -- source and time, already formatted
    on_mark_read = nil, -- function(message)
}

function MessageView:init()
    local width, height = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(16)
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }

    local title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        align = "left",
        with_bottom_line = true,
        title = self.message.title,
        subtitle = self.subtitle,
        left_icon = "chevron.left",
        left_icon_tap_callback = function() self:close() end,
        show_parent = self,
    }

    local read_button = Button:new{
        text = _("Mark as read"),
        text_font_size = 22,
        width = math.floor(width * 0.34),
        padding_v = Screen:scaleBySize(8),
        show_parent = self,
        callback = function()
            self:close()
            if self.on_mark_read then
                self.on_mark_read(self.message)
            end
        end,
    }
    local button_size = read_button:getSize()
    read_button.overlap_offset = { width - button_size.w - margin, height - button_size.h - margin }

    local gap = Screen:scaleBySize(10)
    local body_height = height - title_bar:getSize().h - button_size.h - margin - gap * 2
    local body_text = self.body ~= nil and self.body ~= "" and self.body or self.message.title

    local content = VerticalGroup:new{
        align = "left",
        title_bar,
        VerticalSpan:new{ width = gap },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = margin,
            padding_right = margin,
            margin = 0,
            ScrollHtmlWidget:new{
                html_body = Markdown.toHtml(body_text),
                css = Markdown.CSS,
                default_font_size = Screen:scaleBySize(20),
                width = width - margin * 2,
                height = body_height,
                dialog = self,
            },
        },
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = height },
            allow_mirroring = false,
            content,
            read_button,
        },
    }
end

function MessageView:close()
    UIManager:close(self)
    if self.on_closed then
        self.on_closed()
    end
end

function MessageView:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function MessageView:onCloseWidget()
    -- Closing doesn't refresh the display by itself, so the dashboard underneath needs this.
    UIManager:setDirty(nil, "full")
end

return MessageView

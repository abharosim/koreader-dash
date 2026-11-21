-- The Audi reading pane: a header and a scrolling Markdown body, or the idle line.
-- The dashboard supplies the bottom bar, so this is not its own screen.

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Markdown = require("dash_markdown")
local Screen = Device.screen

local AudiView = {}

local function pageButton(label, enabled, width, show_parent, callback)
    return Button:new{
        text = label,
        text_font_size = 18,
        width = width,
        enabled = enabled,
        show_parent = show_parent,
        callback = callback,
    }
end

-- opts: width, height, entry, body, index, total, time_text, show_parent, on_page.
-- Returns widget, scroll, prev, next. scroll/prev/next are nil when there is no entry.
function AudiView.build(opts)
    if not opts.entry then
        return {
            widget = CenterContainer:new{
                dimen = Geom:new{ w = opts.width, h = opts.height },
                TextWidget:new{
                    text = "暂无内容",
                    face = Font:getFace("infofont", 24),
                },
            },
        }
    end

    local width = opts.width
    local entry = opts.entry
    local button_width = math.floor(width * 0.1)
    local prev = pageButton("<", opts.index > 1, button_width, opts.show_parent, function()
        opts.on_page(-1)
    end)
    local next_button = pageButton(">", opts.index < opts.total, button_width, opts.show_parent, function()
        opts.on_page(1)
    end)
    local position = TextWidget:new{
        text = string.format("%d/%d", opts.index, opts.total),
        face = Font:getFace("infofont", 16),
    }
    local pager = HorizontalGroup:new{
        prev,
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width * 0.14), h = position:getSize().h },
            position,
        },
        next_button,
    }
    local title = TextWidget:new{
        text = entry.title ~= "" and entry.title or " ",
        face = Font:getFace("infofont", 22),
        bold = true,
        max_width = math.max(1, width - pager:getSize().w - Screen:scaleBySize(8)),
    }
    pager.overlap_align = "right"
    local title_height = math.max(title:getSize().h, pager:getSize().h)
    local parts = { "#" .. tostring(entry.ref) }
    if type(entry.source) == "string" and entry.source ~= "" then
        table.insert(parts, entry.source)
    end
    if opts.time_text and opts.time_text ~= "" then
        table.insert(parts, opts.time_text)
    end
    local meta = TextWidget:new{
        text = table.concat(parts, " · "),
        face = Font:getFace("infofont", 16),
        max_width = width,
    }
    local header = VerticalGroup:new{
        align = "left",
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = title_height },
            allow_mirroring = false,
            title,
            pager,
        },
        meta,
    }

    local gap = Screen:scaleBySize(8)
    local body_height = math.max(Screen:scaleBySize(40), opts.height - header:getSize().h - gap)
    local body = opts.body
    if type(body) ~= "string" or body == "" then
        body = entry.title ~= "" and entry.title or " "
    end
    local scroll = ScrollHtmlWidget:new{
        html_body = Markdown.toHtml(body),
        css = Markdown.CSS,
        default_font_size = Screen:scaleBySize(20),
        width = width,
        height = body_height,
        dialog = opts.show_parent,
    }
    return {
        widget = VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = gap },
            scroll,
        },
        scroll = scroll,
        prev = prev,
        next = next_button,
    }
end

return AudiView

-- The Audi reading pane: a header and a scrolling Markdown body, or the idle line.
-- The dashboard supplies the bottom bar, so this is not its own screen.
--
-- The page inset is 4. The HTML box has no page or body margin, so the first
-- line lines up with the title. The scrollbar stays; its gutter is 2, not the
-- widget's default 12.

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
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

-- Outer inset of the Audi page. The dashboard's other screens use 16.
AudiView.PAGE_MARGIN = 4
-- Space between the header and the body. Was 4, and 8 before that.
AudiView.BLOCK_GAP = 2
-- ScrollHtmlWidget defaults are 6 and 12. The span is the empty gutter beside the bar.
AudiView.SCROLL_BAR_WIDTH = 4
AudiView.SCROLL_GUTTER = 2

-- MuPDF's own HTML stylesheet adds a page margin and a body margin. Both are
-- cleared here so the text starts on the header's left edge, with no gap above
-- the first heading and no band under the last line.
AudiView.CSS = [[
@page { margin: 0; padding: 0; }
html, body { margin: 0; padding: 0; line-height: 1.15; }
h1 { font-size: 1.25em; margin: 0 0 0.15em 0; padding: 0; }
h2 { font-size: 1.12em; margin: 0 0 0.1em 0; padding: 0; }
h3, h4, h5, h6 { font-size: 1.05em; margin: 0 0 0.08em 0; padding: 0; }
p { margin: 0 0 0.2em 0; padding: 0; }
ul, ol { margin: 0 0 0.2em 0; padding: 0 0 0 1em; }
li { margin: 0; padding: 0; }
blockquote { margin: 0.15em 0 0.2em 0; padding: 0 0 0 0.4em; border-left: 2px solid black; }
pre { margin: 0.15em 0 0.2em 0; padding: 0.1em; border: 1px solid #888; white-space: pre-wrap; font-size: 0.85em; }
code { font-family: monospace; font-size: 0.9em; }
table { border-collapse: collapse; margin: 0.15em 0 0.2em 0; }
th, td { border: 1px solid black; padding: 0.05em 0.2em; }
th { font-weight: bold; }
hr { border: 0; border-top: 1px solid black; margin: 0.25em 0; }
]]

local function pageButton(label, enabled, width, show_parent, callback)
    return Button:new{
        text = label,
        text_font_size = 16,
        padding = 0,
        padding_h = Screen:scaleBySize(4),
        padding_v = 0,
        margin = 0,
        width = width,
        enabled = enabled,
        show_parent = show_parent,
        callback = callback,
    }
end

-- opts: width, height, entry, body, index, total, time_text, font_size, show_parent, on_page.
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
        face = Font:getFace("infofont", 15),
    }
    local pager = HorizontalGroup:new{
        prev,
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width * 0.12), h = position:getSize().h },
            position,
        },
        next_button,
    }
    local title = TextWidget:new{
        text = entry.title ~= "" and entry.title or " ",
        face = Font:getFace("infofont", 20),
        bold = true,
        max_width = math.max(1, width - pager:getSize().w - Screen:scaleBySize(AudiView.BLOCK_GAP)),
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
        face = Font:getFace("infofont", 14),
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

    local gap = Screen:scaleBySize(AudiView.BLOCK_GAP)
    local body_height = math.max(Screen:scaleBySize(40), opts.height - header:getSize().h - gap)
    local body = opts.body
    if type(body) ~= "string" or body == "" then
        body = entry.title ~= "" and entry.title or " "
    end
    local scroll = ScrollHtmlWidget:new{
        html_body = Markdown.toHtml(body),
        css = AudiView.CSS,
        default_font_size = Screen:scaleBySize(opts.font_size or 18),
        width = width,
        height = body_height,
        dialog = opts.show_parent,
        scroll_bar_width = Screen:scaleBySize(AudiView.SCROLL_BAR_WIDTH),
        text_scroll_span = Screen:scaleBySize(AudiView.SCROLL_GUTTER),
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

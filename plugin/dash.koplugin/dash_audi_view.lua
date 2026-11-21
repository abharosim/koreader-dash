-- The Audi reading pane: a header and a scrolling Markdown body, or the idle line.
-- The dashboard supplies the bottom bar, so this is not its own screen.
--
-- Spacing is about half of the first Audi layout (page margin 16 -> 8, block gap 8 -> 4)
-- and the body face defaults to 18, down from 20. A- / A+ change that size.

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
local AudiFont = require("dash_audi_font")
local Markdown = require("dash_markdown")
local Screen = Device.screen

local AudiView = {}

-- Half the dashboard's 16-point page margin. The dashboard insets Audi content by this.
AudiView.PAGE_MARGIN = 8
-- Half the previous 8-point gap between the header and the body.
AudiView.BLOCK_GAP = 4
AudiView.FONT_MIN = AudiFont.MIN
AudiView.FONT_MAX = AudiFont.MAX
AudiView.FONT_STEP = AudiFont.STEP
AudiView.FONT_DEFAULT = AudiFont.DEFAULT

-- Tighter than Markdown.CSS so a long note fits more lines. The inbox reader keeps the original.
AudiView.CSS = [[
body { margin: 0; line-height: 1.2; }
h1 { font-size: 1.35em; margin: 0.3em 0 0.15em 0; }
h2 { font-size: 1.2em; margin: 0.3em 0 0.15em 0; }
h3, h4, h5, h6 { font-size: 1.05em; margin: 0.25em 0 0.1em 0; }
p { margin: 0 0 0.3em 0; }
ul, ol { margin: 0 0 0.3em 0; padding-left: 1.1em; }
li { margin: 0.05em 0; }
blockquote { margin: 0.2em 0 0.3em 0; padding-left: 0.5em; border-left: 3px solid black; }
pre { margin: 0.2em 0 0.4em 0; padding: 0.2em; border: 1px solid #888; white-space: pre-wrap; font-size: 0.85em; }
code { font-family: monospace; font-size: 0.9em; }
table { border-collapse: collapse; margin: 0.2em 0 0.4em 0; }
th, td { border: 1px solid black; padding: 0.08em 0.25em; }
th { font-weight: bold; }
hr { border: 0; border-top: 1px solid black; margin: 0.4em 0; }
]]

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

-- A- and A+ sit in the header. opts.on_font(delta) persists and repaginates.
local function fontBar(opts, width)
    local size = opts.font_size or AudiView.FONT_DEFAULT
    local button_width = math.max(Screen:scaleBySize(44), math.floor(width * 0.1))
    local smaller = pageButton("A-", size > AudiView.FONT_MIN, button_width, opts.show_parent, function()
        if opts.on_font then
            opts.on_font(-AudiView.FONT_STEP)
        end
    end)
    local larger = pageButton("A+", size < AudiView.FONT_MAX, button_width, opts.show_parent, function()
        if opts.on_font then
            opts.on_font(AudiView.FONT_STEP)
        end
    end)
    local label = TextWidget:new{
        text = tostring(size),
        face = Font:getFace("infofont", 16),
    }
    local bar = HorizontalGroup:new{
        align = "center",
        smaller,
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:scaleBySize(32), h = label:getSize().h },
            label,
        },
        larger,
    }
    return bar, smaller, larger
end

-- opts: width, height, entry, body, index, total, time_text, font_size, show_parent,
--       on_page, on_font.
-- Returns widget, scroll, prev, next, font_smaller, font_larger.
-- scroll/prev/next are nil when there is no entry.
function AudiView.build(opts)
    local fonts, font_smaller, font_larger = fontBar(opts, opts.width)
    if not opts.entry then
        local message = TextWidget:new{
            text = "暂无内容",
            face = Font:getFace("infofont", 24),
        }
        fonts.overlap_align = "right"
        return {
            widget = OverlapGroup:new{
                dimen = Geom:new{ w = opts.width, h = opts.height },
                allow_mirroring = false,
                CenterContainer:new{
                    dimen = Geom:new{ w = opts.width, h = opts.height },
                    message,
                },
                fonts,
            },
            font_smaller = font_smaller,
            font_larger = font_larger,
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
        face = Font:getFace("infofont", 16),
        max_width = math.max(1, width - fonts:getSize().w - Screen:scaleBySize(AudiView.BLOCK_GAP)),
    }
    fonts.overlap_align = "right"
    local meta_height = math.max(meta:getSize().h, fonts:getSize().h)
    local header = VerticalGroup:new{
        align = "left",
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = title_height },
            allow_mirroring = false,
            title,
            pager,
        },
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = meta_height },
            allow_mirroring = false,
            meta,
            fonts,
        },
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
        default_font_size = Screen:scaleBySize(opts.font_size or AudiView.FONT_DEFAULT),
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
        font_smaller = font_smaller,
        font_larger = font_larger,
    }
end

return AudiView

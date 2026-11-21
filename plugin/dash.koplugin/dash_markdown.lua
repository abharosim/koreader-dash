-- Markdown to HTML for message bodies, plus plain-text previews.
-- Every character of the input is escaped, so raw HTML in a message shows as text and only
-- Markdown syntax becomes markup. KOReader's bundled converter passes raw HTML through,
-- which is why this exists. No KOReader imports.

local Markdown = {}

-- Shared by the inbox reader and Audi view. Raw HTML never reaches this stylesheet:
-- toHtml escapes the source first, and only Markdown syntax becomes tags.
Markdown.CSS = [[
body { margin: 0; line-height: 1.35; }
h1 { font-size: 1.45em; margin: 0.6em 0 0.3em 0; }
h2 { font-size: 1.25em; margin: 0.6em 0 0.3em 0; }
h3, h4, h5, h6 { font-size: 1.1em; margin: 0.5em 0 0.2em 0; }
p { margin: 0 0 0.6em 0; }
ul, ol { margin: 0 0 0.6em 0; padding-left: 1.4em; }
li { margin: 0.1em 0; }
blockquote { margin: 0.4em 0 0.6em 0; padding-left: 0.8em; border-left: 3px solid black; }
pre { margin: 0.4em 0 0.8em 0; padding: 0.4em; border: 1px solid #888; white-space: pre-wrap; font-size: 0.85em; }
code { font-family: monospace; font-size: 0.9em; }
table { border-collapse: collapse; margin: 0.4em 0 0.8em 0; }
th, td { border: 1px solid black; padding: 0.15em 0.4em; }
th { font-weight: bold; }
hr { border: 0; border-top: 1px solid black; margin: 0.8em 0; }
]]

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Code spans are swapped out first so nothing inside them is treated as Markdown.
local function inline(text)
    local codes = {}
    text = text:gsub("[\1\2]", "")
    text = text:gsub("(`+)(.-)%1", function(_, code)
        table.insert(codes, escape(code:match("^%s?(.-)%s?$")))
        return "\1" .. #codes .. "\2"
    end)
    text = escape(text)
    text = text:gsub("!%[(.-)%]%b()", function(alt)
        return alt ~= "" and ("[" .. alt .. "]") or ""
    end)
    text = text:gsub("%[(.-)%]%b()", "<u>%1</u>")
    text = text:gsub("&lt;(https?://[^%s]-)&gt;", "<u>%1</u>")
    text = text:gsub("%*%*(%S.-)%*%*", "<strong>%1</strong>")
    text = text:gsub("%f[%w_]__(%S.-)__%f[^%w_]", "<strong>%1</strong>")
    text = text:gsub("%*(%S.-)%*", "<em>%1</em>")
    text = text:gsub("%f[%w_]_(%S.-)_%f[^%w_]", "<em>%1</em>")
    text = text:gsub("~~(%S.-)~~", "<s>%1</s>")
    text = text:gsub("\1(%d+)\2", function(index)
        return "<code>" .. codes[tonumber(index)] .. "</code>"
    end)
    return text
end

local function isBlank(line)
    return line:match("^%s*$") ~= nil
end

local function headingOf(line)
    local hashes, text = line:match("^%s?%s?%s?(#+)%s+(.-)%s*#*%s*$")
    if not hashes then
        hashes = line:match("^%s?%s?%s?(#+)%s*$")
        text = ""
    end
    if hashes and #hashes <= 6 then
        return #hashes, text
    end
    return nil
end

local function isRule(line)
    local compact = line:gsub("%s", "")
    return #compact >= 3 and (compact:match("^%-+$") or compact:match("^%*+$") or compact:match("^_+$")) ~= nil
end

local function fenceOf(line)
    return line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
end

-- Returns indent, marker type ("ul" or "ol"), number, and the item's text.
local function listItemOf(line)
    local indent, text = line:match("^(%s*)[%-%*%+]%s+(.*)$")
    if indent then
        return #indent, "ul", nil, text
    end
    local number
    indent, number, text = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
    if indent then
        return #indent, "ol", tonumber(number), text
    end
    return nil
end

local function splitRow(line)
    local trimmed = line:match("^%s*|?(.-)|?%s*$")
    local cells = {}
    for cell in (trimmed .. "|"):gmatch("(.-)|") do
        table.insert(cells, cell:match("^%s*(.-)%s*$"))
    end
    return cells
end

local function isTableDivider(line)
    return line and line:find("-", 1, true) and line:match("^%s*|?[%s:|%-]+|?%s*$") ~= nil
end

local function startsTable(lines, i)
    return lines[i]:find("|", 1, true) ~= nil and isTableDivider(lines[i + 1])
end

local function startsBlock(lines, i)
    local line = lines[i]
    return headingOf(line) or fenceOf(line) or isRule(line) or line:match("^%s*>")
        or listItemOf(line) or startsTable(lines, i)
end

local parseBlocks

local function parseList(lines, i)
    local base_indent, kind, start = listItemOf(lines[i])
    local items, current = {}, nil
    local tight = true
    local n = #lines

    while i <= n do
        local line = lines[i]
        local indent, item_kind, _, text = listItemOf(line)
        if indent and indent <= base_indent + 1 and item_kind == kind then
            current = { text }
            table.insert(items, current)
        elseif isBlank(line) then
            local next_line = lines[i + 1]
            local next_indent, next_kind
            if next_line then
                next_indent, next_kind = listItemOf(next_line)
            end
            local continues = next_line and not isBlank(next_line) and (
                (next_line:match("^(%s*)"):len() > base_indent)
                or (next_indent and next_indent <= base_indent + 1 and next_kind == kind))
            if not continues then
                break
            end
            tight = false
            table.insert(current, "")
        elseif #line:match("^(%s*)") > base_indent then
            table.insert(current, (line:gsub("^" .. string.rep(" ", base_indent + 2), "", 1)))
        elseif not isBlank(current[#current]) and not startsBlock(lines, i) then
            table.insert(current, line) -- A paragraph continuing without indentation.
        else
            break
        end
        i = i + 1
    end

    local html = {}
    local open_tag = kind
    if kind == "ol" and start and start ~= 1 then
        open_tag = string.format('ol start="%d"', start)
    end
    table.insert(html, "<" .. open_tag .. ">")
    for _, item in ipairs(items) do
        local body = parseBlocks(item)
        if tight then
            body = body:gsub("<p>(.-)</p>", "%1")
        end
        table.insert(html, "<li>" .. body .. "</li>")
    end
    table.insert(html, "</" .. kind .. ">")
    return table.concat(html, "\n"), i
end

local function parseTable(lines, i)
    local header = splitRow(lines[i])
    local html = { "<table>", "<tr>" }
    for _, cell in ipairs(header) do
        table.insert(html, "<th>" .. inline(cell) .. "</th>")
    end
    table.insert(html, "</tr>")
    i = i + 2
    while i <= #lines and not isBlank(lines[i]) and lines[i]:find("|", 1, true) do
        table.insert(html, "<tr>")
        local cells = splitRow(lines[i])
        for column = 1, #header do
            table.insert(html, "<td>" .. inline(cells[column] or "") .. "</td>")
        end
        table.insert(html, "</tr>")
        i = i + 1
    end
    table.insert(html, "</table>")
    return table.concat(html), i
end

parseBlocks = function(lines)
    local html = {}
    local i, n = 1, #lines
    while i <= n do
        local line = lines[i]
        local level, heading_text = headingOf(line)
        local fence = fenceOf(line)

        if isBlank(line) then
            i = i + 1
        elseif fence then
            local code = {}
            i = i + 1
            while i <= n and not lines[i]:match("^%s*" .. fence:sub(1, 1):rep(#fence)) do
                table.insert(code, lines[i])
                i = i + 1
            end
            i = i + 1
            table.insert(html, "<pre><code>" .. escape(table.concat(code, "\n")) .. "</code></pre>")
        elseif level then
            table.insert(html, string.format("<h%d>%s</h%d>", level, inline(heading_text), level))
            i = i + 1
        elseif isRule(line) then
            table.insert(html, "<hr/>")
            i = i + 1
        elseif line:match("^%s*>") then
            local quoted = {}
            while i <= n and lines[i]:match("^%s*>") do
                table.insert(quoted, (lines[i]:gsub("^%s*> ?", "", 1)))
                i = i + 1
            end
            table.insert(html, "<blockquote>" .. parseBlocks(quoted) .. "</blockquote>")
        elseif listItemOf(line) then
            local list
            list, i = parseList(lines, i)
            table.insert(html, list)
        elseif startsTable(lines, i) then
            local tbl
            tbl, i = parseTable(lines, i)
            table.insert(html, tbl)
        else
            local paragraph = {}
            while i <= n and not isBlank(lines[i]) and (#paragraph == 0 or not startsBlock(lines, i)) do
                local text = lines[i]
                local hard_break = text:match("  $") or text:match("\\$")
                text = inline((text:gsub("\\$", ""):match("^%s*(.-)%s*$")))
                table.insert(paragraph, hard_break and (text .. "<br/>") or text)
                i = i + 1
            end
            table.insert(html, "<p>" .. table.concat(paragraph, "\n") .. "</p>")
        end
    end
    return table.concat(html, "\n")
end

local function toLines(text)
    text = text:gsub("\r\n?", "\n"):gsub("\t", "    ")
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

function Markdown.toHtml(text)
    return parseBlocks(toLines(text or ""))
end

-- Cuts at a byte limit without splitting a multi-byte UTF-8 character.
function Markdown.truncateUtf8(text, max_bytes)
    if #text <= max_bytes then
        return text
    end
    local cut = max_bytes
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

-- A short plain-text version for the inbox list.
function Markdown.preview(text, max_bytes)
    max_bytes = max_bytes or 200
    local plain = {}
    local in_code = false
    for _, line in ipairs(toLines(text or "")) do
        if fenceOf(line) then
            in_code = not in_code
        elseif not isTableDivider(line) and not (not in_code and isRule(line)) then
            if not in_code then
                line = line:gsub("^%s*#+%s*", "")
                    :gsub("^%s*>[>%s]*", "")
                    :gsub("^%s*[%-%*%+]%s+", "")
                    :gsub("^%s*%d+[%.%)]%s+", "")
                    :gsub("!%[(.-)%]%b()", "%1")
                    :gsub("%[(.-)%]%b()", "%1")
                    :gsub("|", " ")
                    :gsub("%*%*", ""):gsub("~~", ""):gsub("`", "")
                    :gsub("%f[%w_]_(%S.-)_%f[^%w_]", "%1")
                    :gsub("%*(%S.-)%*", "%1")
            end
            table.insert(plain, line)
        end
    end
    local joined = table.concat(plain, " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #joined <= max_bytes then
        return joined
    end
    return Markdown.truncateUtf8(joined, max_bytes - 3) .. "…"
end

return Markdown

-- The dash home Inbox: unread briefings and Audi history on one list.
-- Pure: no KOReader imports. The HTTP inbox is unchanged; this is only the on-screen list.
--
-- Audi rows come from the Audi store. `action: clear` sets `inbox_hidden` on those
-- entries (the archive stays); hidden rows are left out. `replace_id` updates the
-- same entry, which clears that flag, so the row comes back in place.

local Inbox = {}

local function timeOf(entry)
    if type(entry.display_at) == "number" then
        return entry.display_at
    end
    if type(entry.received_at) == "number" then
        return entry.received_at
    end
    return 0
end

-- messages: inbox messages (read ones are skipped).
-- entries: Audi store entries. Hidden or already-read ones are skipped.
-- Read entries stay in the Audi store so the Audi button can still page through them.
-- Newest first. Equal times break by kind, then id, so the order does not depend on
-- the sort being stable.
function Inbox.merge(messages, entries)
    local items = {}
    if type(messages) == "table" then
        for _, message in ipairs(messages) do
            if type(message) == "table" and not message.read_at then
                items[#items + 1] = {
                    kind = "briefing",
                    at = timeOf(message),
                    id = message.id,
                    message = message,
                }
            end
        end
    end
    if type(entries) == "table" then
        for _, entry in ipairs(entries) do
            if type(entry) == "table" and not entry.inbox_hidden and not entry.read_at then
                items[#items + 1] = {
                    kind = "audi",
                    at = timeOf(entry),
                    id = entry.id,
                    ref = entry.ref,
                    unread = entry.read_at == nil,
                    entry = entry,
                }
            end
        end
    end
    table.sort(items, function(a, b)
        if a.at ~= b.at then
            return a.at > b.at
        end
        if a.kind ~= b.kind then
            return a.kind < b.kind
        end
        return tostring(a.id) < tostring(b.id)
    end)
    return items
end

-- Unread briefings plus Audi entries that have not been shown in Audi fullscreen.
function Inbox.unreadCount(items)
    local count = 0
    for _, item in ipairs(items) do
        if item.kind == "briefing" or item.unread then
            count = count + 1
        end
    end
    return count
end

return Inbox

-- Run: scripts/test.sh
-- Home inbox merge, Audi read state, and the Audi idle timeout. No KOReader UI.
package.path = "plugin/dash.koplugin/?.lua;" .. package.path
local AudiStore = require("dash_audi_store")
local FontSize = require("dash_audi_font")
local Idle = require("dash_audi_idle")
local Inbox = require("dash_inbox")

local dir = assert(os.getenv("KDASH_TEST_DIR"), "KDASH_TEST_DIR is required")
local failures, passed, counter = 0, 0, 0

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

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function newAudi()
    counter = counter + 1
    local events = {}
    local store = AudiStore.new{
        path = string.format("%s/inbox-audi%d.json", dir, counter),
        body_dir = string.format("%s/inbox-audi%d.bodies", dir, counter),
        make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
        now = function() return 1700000000 end,
        on_change = function(info) table.insert(events, info) end,
    }
    return store, events
end

local function ids(items)
    local list = {}
    for index, item in ipairs(items) do
        list[index] = item.kind .. ":" .. tostring(item.id)
    end
    return table.concat(list, ",")
end

test("the merged inbox is newest first and keeps read Audi rows", function()
    local items = Inbox.merge({
        { id = "old-brief", title = "Old", received_at = 100, priority = "high" },
        { id = "new-brief", title = "New", received_at = 300, source = "dada", type = "briefing.daily" },
        { id = "read-brief", title = "Done", received_at = 400, read_at = 401 },
    }, {
        { id = "audi-old", ref = 3, title = "Note", display_at = 200, read_at = 250 },
        { id = "audi-new", ref = 4, title = "Later", display_at = 350 },
        { id = "audi-cleared", ref = 1, title = "Gone", display_at = 500, inbox_hidden = true },
    })
    eq(ids(items), "audi:audi-new,briefing:new-brief,audi:audi-old,briefing:old-brief", "order")
    eq(items[1].unread, true, "new audi unread")
    eq(items[1].ref, 4, "ref")
    eq(items[3].unread, false, "read audi stays")
    eq(Inbox.unreadCount(items), 3, "unread")
    -- High priority no longer jumps ahead of a newer row.
    eq(items[4].id, "old-brief", "old high-priority briefing is last")
end)

test("equal timestamps sort by kind then id", function()
    local items = Inbox.merge(
        { { id = "m", received_at = 10 } },
        { { id = "a", display_at = 10, ref = 1 }, { id = "b", received_at = 10, ref = 2 } }
    )
    eq(ids(items), "audi:a,audi:b,briefing:m", "tie")
end)

test("a cleared Audi entry leaves the list and an update comes back in place", function()
    local store, events = newAudi()
    store:submit{ id = "a", ref = 3, title = "Old title", body = "old" }
    store:submit{ id = "b", ref = 4, title = "Other", body = "x" }
    store:submit{ action = "clear" }
    eq(#store.entries, 2, "archive kept")
    eq(Inbox.merge({}, store.entries)[1], nil, "list empty after clear")
    eq(store.unseen, 0, "badge")
    local before = #events
    local _, retry = store:submit{ id = "a", ref = 9, title = "Old title", body = "old" }
    eq(retry.updated, false, "retry")
    eq(#events, before, "retry is quiet")
    eq(store:get("a").inbox_hidden, true, "retry stays hidden")
    local entry, meta = store:submit{
        id = "other-file",
        replace_id = "a",
        ref = 99,
        title = "New title",
        body = "new body",
    }
    eq(meta.updated, true, "updated")
    eq(entry.id, "a", "same id")
    eq(entry.ref, 3, "same ref")
    eq(entry.read_at, nil, "unread again")
    eq(entry.inbox_hidden, nil, "listed")
    local items = Inbox.merge({}, store.entries)
    eq(#items, 1, "only the updated row")
    eq(items[1].id, "a", "in place")
    eq(items[1].entry.title, "New title", "title")
    eq(items[1].unread, true, "unread flag")
    eq(store:get("b").inbox_hidden, true, "the other stays cleared")
end)

test("displaying an Audi entry marks that entry read and leaves the others", function()
    local store, events = newAudi()
    store:submit{ id = "a", title = "A", body = "a", created_at = "1970-01-01T00:00:00Z" }
    store:submit{ id = "b", title = "B", body = "b", created_at = "1970-01-01T00:00:10Z" }
    eq(store.unseen, 2, "unseen")
    local before = #events
    assert(store:markDisplayed("b"))
    eq(store:get("b").read_at, 1700000000, "read at")
    eq(store:get("a").read_at, nil, "other unread")
    eq(store.unseen, 1, "unseen")
    eq(store.pending_show, false, "the current one was shown")
    assert(not store:markDisplayed("b"))
    eq(#events, before + 1, "second display does not notify")
    local items = Inbox.merge({}, store.entries)
    eq(items[1].id, "b", "newest")
    eq(items[1].unread, false, "shown row")
    eq(items[2].unread, true, "other row")
end)

test("an audi file from before read_at treats history as already read", function()
    local store = newAudi()
    local file = assert(io.open(store.path, "w"))
    file:write([[{"entries":[{"id":"old","seq":1,"ref":2,"title":"Old","source":"Audi","received_at":10},{"id":"fresh","seq":2,"ref":3,"title":"Fresh","source":"Audi","received_at":11}],"next_seq":3,"next_ref":4,"current_id":"fresh","pending_show":true,"unseen":1}]])
    file:close()
    store:load()
    eq(store:get("old").read_at, 10, "old entry read")
    eq(store:get("fresh").read_at, nil, "pending entry stays unread")
    eq(store.read_state, 1, "migrated")
    eq(store.unseen, 1, "badge")
    local items = Inbox.merge({}, store.entries)
    eq(#items, 2, "both listed")
    eq(items[1].id, "fresh", "newer first")
    eq(items[1].unread, true, "pending unread")
    eq(items[2].unread, false, "old read")
end)

test("the idle window is 10 minutes and resume uses the same rule", function()
    eq(Idle.TIMEOUT_SECONDS, 600, "default")
    local start = 1000000
    assert(not Idle.expired(start, start + 599), "599s")
    assert(Idle.expired(start, start + 600), "600s")
    eq(Idle.remaining(start, start + 599), 1, "one second left")
    eq(Idle.remaining(start, start + 600), 0, "none left")
    eq(Idle.remaining(nil, start), 600, "not started")
    assert(not Idle.expired(nil, start), "missing timestamp is not expired")
    eq(Idle.action("dash", start, start + 9999), "cancel", "not in audi")
    eq(Idle.action("audi", start, start + 100), "rearm", "still waiting")
    eq(Idle.action("audi", start, start + 600), "leave", "due")
    -- A second decision after leaving is cancel, so the timer cannot fire twice.
    eq(Idle.action("dash", start, start + 600), "cancel", "already home")
    eq(Idle.action("audi", start, start + 700, 600), "leave", "resume after the window")
    eq(Idle.action("audi", start, start + 100, 600), "rearm", "resume inside the window")
end)

test("a new Audi entry's timestamp would rearm rather than leave", function()
    local arrived = 2000000
    eq(Idle.action("audi", arrived, arrived), "rearm", "just arrived")
    eq(Idle.remaining(arrived, arrived), 600, "full window")
end)

test("Audi body font defaults to 18 and stays inside 14 to 28", function()
    eq(FontSize.DEFAULT, 18, "default")
    eq(FontSize.MIN, 14, "min")
    eq(FontSize.MAX, 28, "max")
    eq(FontSize.STEP, 2, "step")
    eq(FontSize.clamp(nil), 18, "missing")
    eq(FontSize.clamp(20), 20, "saved")
    eq(FontSize.clamp(3), 14, "too small")
    eq(FontSize.clamp(100), 28, "too big")
    eq(FontSize.clamp(18.9), 18, "floor")
    eq(FontSize.adjust(18, 2), 20, "larger")
    eq(FontSize.adjust(18, -2), 16, "smaller")
    eq(FontSize.adjust(14, -2), 14, "min holds")
    eq(FontSize.adjust(28, 2), 28, "max holds")
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

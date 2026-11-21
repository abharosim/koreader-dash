-- Run: scripts/test.sh
package.path = "plugin/dash.koplugin/?.lua;" .. package.path
local json = require("json")
local Api = require("dash_api")
local AudiStore = require("dash_audi_store")
local Store = require("dash_store")

local dir = assert(os.getenv("KDASH_TEST_DIR"), "KDASH_TEST_DIR is required")
local TOKEN = "abcdefabcdefabcdefabcdefabcdefab"
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

local function newAudi(opts)
    counter = counter + 1
    opts = opts or {}
    local events = {}
    local clock = opts.clock or 1700000000
    local store = AudiStore.new{
        path = opts.path or string.format("%s/audi%d.json", dir, counter),
        body_dir = opts.body_dir or string.format("%s/audi%d.bodies", dir, counter),
        make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
        now = opts.now or function() return clock end,
        limit = opts.limit,
        on_change = function(info) table.insert(events, info) end,
    }
    return store, events, clock
end

test("HISTORY_LIMIT is 20", function()
    eq(AudiStore.HISTORY_LIMIT, 20, "limit")
end)

test("a new entry keeps the sender's ref and stores the body apart from the index", function()
    local store = newAudi()
    local body = "## 摘要\n\n`fib.py` 的递归。\n\n" .. string.rep("More detail. ", 80) .. "UNIQUE_TAIL"
    local entry, meta = store:submit{
        id = "audi-20261120-191200",
        ref = 12,
        title = "DeepSeek 审查结果",
        source = "DeepSeek",
        created_at = "1970-01-01T00:00:00Z",
        body = body,
    }
    eq(meta.created, true, "created")
    eq(meta.updated, false, "updated")
    eq(entry.ref, 12, "ref")
    eq(entry.title, "DeepSeek 审查结果", "title")
    eq(entry.source, "DeepSeek", "source")
    eq(entry.created_at, "1970-01-01T00:00:00Z", "created_at")
    eq(entry.display_at, 0, "display_at")
    eq(entry.body, nil, "body not in the index")
    eq(store:getBody(entry), body, "body file")
    eq(entry.preview:sub(1, #"摘要"), "摘要", "preview")
    assert(#entry.preview <= 200, "preview too long")
    eq(store:current().id, entry.id, "current")
    eq(store.pending_show, true, "pending")
    assert(store:flush())
    local index = io.open(store.path):read("*a")
    assert(not index:find("UNIQUE_TAIL", 1, true), "index holds the body")
    assert(#index < 2000, "index too large: " .. #index)
end)

test("a missing ref takes the next audi_seq, and an explicit ref advances it", function()
    local store = newAudi()
    local first = store:submit{ id = "a", title = "One", body = "a" }
    eq(first.ref, 1, "first")
    local second = store:submit{ id = "b", title = "Two", ref = 12, body = "b" }
    eq(second.ref, 12, "explicit")
    local third = store:submit{ id = "c", title = "Three", body = "c" }
    eq(third.ref, 13, "after explicit")
end)

test("the same id with the same title and body is a retry", function()
    local store, events = newAudi()
    store:submit{ id = "a", title = "Hi", source = "DeepSeek", body = "Same" }
    local entry, meta = store:submit{ id = "a", title = "Hi", source = "Other", body = "Same" }
    eq(meta.created, false, "created")
    eq(meta.updated, false, "updated")
    eq(#store.entries, 1, "count")
    eq(entry.ref, 1, "ref")
    eq(entry.source, "DeepSeek", "source left alone")
    eq(store.unseen, 1, "unseen")
    eq(#events, 1, "no second notification")
end)

test("the same id with a new body updates in place and keeps ref", function()
    local store, events = newAudi()
    store:submit{ id = "a", ref = 12, title = "Hi", body = "Old" }
    store:submit{ id = "b", title = "Later", body = "x" }
    local entry, meta = store:submit{ id = "a", ref = 99, title = "Hi", source = "DeepSeek", body = "New" }
    eq(meta.created, false, "created")
    eq(meta.updated, true, "updated")
    eq(entry.ref, 12, "ref kept")
    eq(entry.source, "DeepSeek", "source")
    eq(store:getBody(entry), "New", "body")
    eq(#store.entries, 2, "count")
    eq(store.entries[1].id, "a", "stays in place")
    eq(store:current().id, "a", "current")
    eq(events[#events].kind, "updated", "kind")
    eq(events[#events].show, true, "show")
end)

test("replace_id updates that entry and keeps its ref", function()
    local store = newAudi()
    store:submit{ id = "audi-20261120-191200", ref = 12, title = "Old", source = "Audi", body = "Old body" }
    local entry, meta = store:submit{
        id = "audi-20261120-191559-update",
        replace_id = "audi-20261120-191200",
        ref = 12,
        title = "New title",
        source = "DeepSeek",
        body = "New body",
    }
    eq(meta.updated, true, "updated")
    eq(meta.created, false, "created")
    eq(entry.id, "audi-20261120-191200", "id kept")
    eq(entry.ref, 12, "ref kept")
    eq(entry.title, "New title", "title")
    eq(store:getBody(entry), "New body", "body")
    eq(store:get("audi-20261120-191559-update"), nil, "update file id is not a new entry")
    eq(#store.entries, 1, "count")
end)

test("replace_id of a missing entry is a new entry", function()
    local store = newAudi()
    local entry, meta = store:submit{
        id = "fresh",
        replace_id = "gone",
        ref = 4,
        title = "New",
        body = "Body",
    }
    eq(meta.created, true, "created")
    eq(entry.id, "fresh", "id")
    eq(entry.ref, 4, "ref")
    eq(store:get("gone"), nil, "replace_id not created")
end)

test("clear goes idle and keeps history", function()
    local store, events = newAudi()
    store:submit{ id = "a", ref = 12, title = "One", body = "A" }
    store:submit{ id = "b", ref = 13, title = "Two", body = "B" }
    local entry, meta = store:submit{ id = "clear-1", action = "clear" }
    eq(entry, nil, "no entry")
    eq(meta.cleared, true, "cleared")
    eq(store:current(), nil, "idle")
    eq(store:currentRef(), nil, "ref")
    eq(#store.entries, 2, "history")
    eq(store:get("a").ref, 12, "first kept")
    eq(store:getBody(store:get("b")), "B", "body kept")
    eq(events[#events].kind, "cleared", "kind")
    eq(store.pending_show, false, "pending")
    local _, again = store:submit{ action = "clear" }
    eq(again.cleared, true, "second clear")
    eq(#events, 3, "second clear does not notify")
end)

test("the 21st entry drops the oldest and the list stays at 20", function()
    local store = newAudi()
    for i = 1, 21 do
        store:submit{ id = "e" .. i, title = "T" .. i, body = "body " .. i }
    end
    eq(#store.entries, 20, "count")
    eq(store:get("e1"), nil, "oldest dropped")
    eq(store:get("e2").ref, 2, "next kept")
    eq(store:get("e21").title, "T21", "newest")
    eq(store:current().id, "e21", "current is newest")
    eq(store:getBody(store:get("e21")), "body 21", "newest body")
end)

test("a lower history limit from options drops sooner", function()
    local store = newAudi{ limit = 2 }
    store:submit{ id = "a", title = "A", body = "a" }
    store:submit{ id = "b", title = "B", body = "b" }
    store:submit{ id = "c", title = "C", body = "c" }
    eq(#store.entries, 2, "count")
    eq(store:get("a"), nil, "dropped")
    eq(store:get("c").id, "c", "kept")
end)

test("created_at with a numeric offset becomes the display time", function()
    local store = newAudi()
    local entry = store:submit{
        id = "t",
        title = "T",
        created_at = "1970-01-01T00:00:00-05:00",
        body = "x",
    }
    eq(entry.display_at, 5 * 3600, "display_at")
end)

test("an unreadable created_at falls back to received_at", function()
    local store = newAudi()
    local entry = store:submit{ id = "t", title = "T", created_at = "tomorrow", body = "x" }
    eq(entry.display_at, 1700000000, "display_at")
    eq(entry.received_at, 1700000000, "received_at")
end)

test("audi entries live in their own store, not the inbox", function()
    local audi = newAudi()
    local inbox = Store.new{
        path = dir .. "/inbox-beside.json",
        body_dir = dir .. "/inbox-beside.bodies",
        make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
        now = function() return 1700000000 end,
    }
    audi:submit{ id = "audi-only", title = "Only audi", body = "secret audi body" }
    eq(#inbox.messages, 0, "inbox count")
    eq(inbox:getMessage("audi-only"), nil, "inbox id")
end)

test("save and load round-trip history, ref and the idle flag", function()
    local store = newAudi()
    store:submit{ id = "a", ref = 7, title = "Hi 你好", body = "Body" }
    store:submit{ action = "clear" }
    assert(store:flush())
    local again = AudiStore.new{
        path = store.path,
        body_dir = store.body_dir,
        make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
        now = function() return 42 end,
    }
    again:load()
    eq(#again.entries, 1, "count")
    eq(again:get("a").ref, 7, "ref")
    eq(again:get("a").title, "Hi 你好", "title")
    eq(again:getBody(again:get("a")), "Body", "body")
    eq(again:current(), nil, "still idle")
    eq(again.next_ref, 8, "next ref")
end)

local setups = 0
local function setup()
    setups = setups + 1
    local clock = { now = 5000 }
    local store = Store.new{
        path = string.format("%s/api-inbox%d.json", dir, setups),
        body_dir = string.format("%s/api-inbox%d.bodies", dir, setups),
        make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
        now = function() return clock.now end,
    }
    local audi = AudiStore.new{
        path = string.format("%s/api-audi%d.json", dir, setups),
        body_dir = string.format("%s/api-audi%d.bodies", dir, setups),
        make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
        now = function() return clock.now end,
    }
    local api = Api.new{
        store = store,
        audi = audi,
        token = TOKEN,
        now = function() return clock.now end,
    }
    return api, store, audi, clock
end

local function call(api, method, path, body, token)
    local status, response = api:handle{
        method = method,
        path = path,
        body = body,
        headers = { authorization = token and ("Bearer " .. token) or "" },
    }
    local decoded = response ~= "" and json.decode(response) or nil
    return status, decoded, response
end

test("POST /v1/audi needs the token", function()
    local api = setup()
    eq(call(api, "POST", "/v1/audi", '{"title":"Hi","body":"x"}', "wrong"), 401, "wrong")
    eq(call(api, "GET", "/v1/audi"), 401, "missing")
    eq(call(api, "POST", "/v1/audi/clear", "{}"), 401, "clear")
end)

test("POST /v1/audi creates an entry and returns 201 and ref", function()
    local api, _, audi = setup()
    local status, body = call(api, "POST", "/v1/audi",
        '{"id":"audi-test-12","ref":12,"title":"测试第 12 条","source":"DeepSeek","body":"## 摘要\\n\\n- 第一点"}',
        TOKEN)
    eq(status, 201, "status")
    eq(body.id, "audi-test-12", "id")
    eq(body.ref, 12, "ref")
    eq(body.created, true, "created")
    eq(body.updated, false, "updated")
    eq(#audi.entries, 1, "stored")
end)

test("retrying the same audi content returns 200 updated false and does not add a row", function()
    local api, _, audi = setup()
    local payload = '{"id":"a","ref":3,"title":"Hi","body":"Same"}'
    call(api, "POST", "/v1/audi", payload, TOKEN)
    local status, body = call(api, "POST", "/v1/audi", payload, TOKEN)
    eq(status, 200, "status")
    eq(body.updated, false, "updated")
    eq(body.created, false, "created")
    eq(body.ref, 3, "ref")
    eq(#audi.entries, 1, "count")
end)

test("changing the body of an id, or replace_id, updates and keeps ref", function()
    local api, _, audi = setup()
    call(api, "POST", "/v1/audi", '{"id":"a","ref":12,"title":"Hi","body":"Old"}', TOKEN)
    local status, body = call(api, "POST", "/v1/audi", '{"id":"a","ref":99,"title":"Hi","body":"New"}', TOKEN)
    eq(status, 200, "status")
    eq(body.updated, true, "updated")
    eq(body.ref, 12, "ref")
    eq(audi:getBody(audi:get("a")), "New", "body")
    local replaced_status, replaced = call(api, "POST", "/v1/audi",
        '{"id":"other","replace_id":"a","ref":1,"title":"Edited","body":"Replaced"}', TOKEN)
    eq(replaced_status, 200, "replace status")
    eq(replaced.updated, true, "replace updated")
    eq(replaced.id, "a", "id")
    eq(replaced.ref, 12, "replace ref")
    eq(#audi.entries, 1, "count")
end)

test("action clear and POST /v1/audi/clear go idle and keep history", function()
    local api, _, audi = setup()
    call(api, "POST", "/v1/audi", '{"id":"a","ref":12,"title":"Hi","body":"Body"}', TOKEN)
    local status, body, raw = call(api, "POST", "/v1/audi", '{"id":"c","action":"clear"}', TOKEN)
    eq(status, 200, "status")
    assert(raw:find('"cleared":true', 1, true), raw)
    eq(body.cleared, true, "cleared")
    eq(#audi.entries, 1, "history after action")
    eq(audi:current(), nil, "idle")
    call(api, "POST", "/v1/audi", '{"id":"b","title":"Two","body":"x"}', TOKEN)
    eq(call(api, "POST", "/v1/audi/clear", "", TOKEN), 200, "clear route")
    eq(#audi.entries, 2, "history after route")
    eq(audi:current(), nil, "idle again")
end)

test("the 21st POST drops the oldest audi entry", function()
    local api, _, audi = setup()
    for i = 1, 21 do
        local status = call(api, "POST", "/v1/audi",
            string.format('{"id":"e%d","title":"T%d","body":"b%d"}', i, i, i), TOKEN)
        eq(status, 201, "status " .. i)
    end
    eq(#audi.entries, 20, "count")
    eq(audi:get("e1"), nil, "oldest")
    eq(audi:get("e21").title, "T21", "newest")
end)

test("audi entries do not appear in GET /v1/inbox", function()
    local api, inbox = setup()
    call(api, "POST", "/v1/inbox", '{"id":"inbox-1","title":"Inbox hello","body":"from inbox"}', TOKEN)
    call(api, "POST", "/v1/audi", '{"id":"audi-1","title":"Audi hello","body":"from audi"}', TOKEN)
    local _, list, raw = call(api, "GET", "/v1/inbox", nil, TOKEN)
    eq(#list.messages, 1, "inbox count")
    eq(list.messages[1].id, "inbox-1", "inbox id")
    eq(raw:find("Audi hello", 1, true), nil, "audi title in inbox")
    eq(raw:find("from audi", 1, true), nil, "audi body in inbox")
    eq(#inbox.messages, 1, "store count")
end)

test("GET /v1/audi lists without bodies, newest last", function()
    local api = setup()
    call(api, "POST", "/v1/audi", '{"id":"a","ref":1,"title":"First","source":"Audi","body":"Secret one"}', TOKEN)
    call(api, "POST", "/v1/audi", '{"id":"b","ref":2,"title":"Second","body":"Secret two"}', TOKEN)
    local status, list, raw = call(api, "GET", "/v1/audi", nil, TOKEN)
    eq(status, 200, "status")
    eq(#list.entries, 2, "count")
    eq(list.entries[1].id, "a", "oldest first")
    eq(list.entries[2].id, "b", "newest last")
    eq(list.entries[2].ref, 2, "ref")
    eq(list.entries[1].preview, "Secret one", "preview")
    eq(raw:find("Secret one", 1, true) ~= nil, true, "preview is the plain start, not a hidden field")
    eq(raw:find('"body"', 1, true), nil, "body field in list")
end)

test("an empty audi list encodes entries as an array", function()
    local api = setup()
    local _, _, raw = call(api, "GET", "/v1/audi", nil, TOKEN)
    assert(raw:find('"entries":[]', 1, true), raw)
end)

test("GET /v1/audi/{id} returns the body", function()
    local api = setup()
    call(api, "POST", "/v1/audi", '{"id":"a","title":"One","body":"Details"}', TOKEN)
    local status, entry = call(api, "GET", "/v1/audi/a", nil, TOKEN)
    eq(status, 200, "status")
    eq(entry.body, "Details", "body")
    eq(entry.ref, 1, "ref")
    eq(call(api, "GET", "/v1/audi/missing", nil, TOKEN), 404, "missing")
end)

test("DELETE /v1/audi/{id} can be repeated", function()
    local api, _, audi = setup()
    call(api, "POST", "/v1/audi", '{"id":"a","title":"One","body":"x"}', TOKEN)
    eq(call(api, "DELETE", "/v1/audi/a", nil, TOKEN), 204, "first")
    eq(call(api, "DELETE", "/v1/audi/a", nil, TOKEN), 204, "second")
    eq(#audi.entries, 0, "count")
end)

test("health reports audi_current_ref, null when idle", function()
    local api = setup()
    local _, _, idle = call(api, "GET", "/v1/health", nil, TOKEN)
    assert(idle:find('"audi_current_ref":null', 1, true), idle)
    call(api, "POST", "/v1/audi", '{"id":"a","ref":12,"title":"Hi","body":"x"}', TOKEN)
    local _, showing = call(api, "GET", "/v1/health", nil, TOKEN)
    eq(showing.audi_current_ref, 12, "ref")
    call(api, "POST", "/v1/audi/clear", "", TOKEN)
    local _, _, cleared = call(api, "GET", "/v1/health", nil, TOKEN)
    assert(cleared:find('"audi_current_ref":null', 1, true), cleared)
end)

test("audi routes validate fields and count toward the rate limit", function()
    local api, _, _, clock = setup()
    eq(call(api, "POST", "/v1/audi", '{"ref":0,"title":"x"}', TOKEN), 400, "ref 0")
    eq(call(api, "POST", "/v1/audi", '{"ref":"12","title":"x"}', TOKEN), 400, "ref string")
    eq(call(api, "POST", "/v1/audi", '{"action":"drop"}', TOKEN), 400, "action")
    eq(call(api, "POST", "/v1/audi", '{"title":"x","id":"bad id"}', TOKEN), 400, "id")
    eq(call(api, "GET", "/v1/audi/clear", nil, TOKEN), 405, "clear method")
    for i = 1, 56 do
        eq(call(api, "POST", "/v1/audi", string.format('{"id":"r%d","title":"t"}', i), TOKEN), 201, "post " .. i)
    end
    -- 4 rejects above plus 56 creates is 60 changes; the next one is limited.
    local status, body = call(api, "POST", "/v1/audi", '{"id":"overflow","title":"t"}', TOKEN)
    eq(status, 429, "status")
    eq(body.retry_after, 60, "retry_after")
    eq(call(api, "GET", "/v1/audi", nil, TOKEN), 200, "read still works")
    clock.now = clock.now + 60
    eq(call(api, "POST", "/v1/audi", '{"id":"after","title":"t"}', TOKEN), 201, "after reset")
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

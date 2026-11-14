-- Run: scripts/test.sh
package.path = "plugin/dash.koplugin/?.lua;" .. package.path
local json = require("json")
local Store = require("dash_store")

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

local function newStore(opts)
    counter = counter + 1
    opts = opts or {}
    opts.path = opts.path or string.format("%s/store%d.json", dir, counter)
    opts.body_dir = opts.body_dir or (opts.path .. ".bodies")
    opts.make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end
    local clock = opts.clock or 1000
    opts.now = opts.now or function() return clock end
    return Store.new(opts)
end

local function patch(text) return json.decode(text) end

test("a partial update changes only the named fields", function()
    local store = newStore()
    store:mergeState(patch('{"weather":{"summary":"Rain","detail":"Cold"},"todo":{"count":1}}'))
    store:mergeState(patch('{"weather":{"summary":"Sun"}}'))
    eq(store.state.weather.summary, "Sun", "summary")
    eq(store.state.weather.detail, "Cold", "detail kept")
    eq(store.state.todo.count, 1, "todo kept")
end)

test("null removes a field", function()
    local store = newStore()
    store:mergeState(patch('{"weather":{"summary":"Rain","detail":"Cold"}}'))
    store:mergeState(patch('{"weather":{"detail":null}}'))
    eq(store.state.weather.detail, nil, "detail")
    eq(store.state.weather.summary, "Rain", "summary")
end)

test("null inside a new object isn't stored", function()
    local store = newStore()
    store:mergeState(patch('{"a":{"b":null,"c":1}}'))
    eq(store.state.a.b, nil, "b")
    eq(store.state.a.c, 1, "c")
end)

test("arrays are replaced, not merged", function()
    local store = newStore()
    store:mergeState(patch('{"list":[1,2,3]}'))
    store:mergeState(patch('{"list":[9]}'))
    eq(#store.state.list, 1, "length")
    eq(store.state.list[1], 9, "value")
end)

test("sending the same values reports no change and doesn't notify", function()
    local changes = 0
    local store = newStore{ on_change = function() changes = changes + 1 end }
    eq(store:mergeState(patch('{"todo":{"count":3}}')), true, "first")
    eq(store:mergeState(patch('{"todo":{"count":3}}')), false, "second")
    eq(changes, 1, "notifications")
end)

test("rejects an oversized state and keeps the old one", function()
    local store = newStore()
    store:mergeState(patch('{"a":1}'))
    local changed, err = store:mergeState({ big = string.rep("x", 70 * 1024) })
    eq(changed, nil, "changed")
    eq(err, "state_too_large", "error")
    eq(store.state.a, 1, "old state")
    eq(store.state.big, nil, "new value")
end)

test("adds messages with generated ids and defaults", function()
    local store = newStore()
    local message, created = store:addMessage{ title = "Hi" }
    eq(created, true, "created")
    eq(message.priority, "normal", "priority")
    eq(message.received_at, 1000, "time")
    assert(message.id, "no id")
    eq(store:unreadCount(), 1, "unread")
end)

test("a retry with the same id doesn't duplicate or reopen a message", function()
    local store = newStore()
    store:addMessage{ id = "a", title = "Hi" }
    store:setRead("a", true)
    local _, created = store:addMessage{ id = "a", title = "Hi" }
    eq(created, false, "created")
    eq(#store.messages, 1, "count")
    eq(store:unreadCount(), 0, "unread")
end)

test("unread order is high priority first, then oldest first", function()
    local store = newStore()
    store:addMessage{ id = "old", title = "1" }
    store:addMessage{ id = "new", title = "2" }
    store:addMessage{ id = "urgent", title = "3", priority = "high" }
    local unread = store:unreadMessages()
    eq(unread[1].id, "urgent", "first")
    eq(unread[2].id, "old", "second")
    eq(unread[3].id, "new", "third")
end)

test("mark read and unread both work", function()
    local store = newStore()
    store:addMessage{ id = "a", title = "Hi" }
    assert(store:setRead("a", true).read_at, "read_at missing")
    eq(store:unreadCount(), 0, "after read")
    eq(store:setRead("a", false).read_at, nil, "read_at")
    eq(store:unreadCount(), 1, "after unread")
    eq(store:setRead("missing", true), nil, "unknown id")
end)

test("mark all read clears the unread list in one change", function()
    local changes = 0
    local store = newStore()
    store:addMessage{ id = "a", title = "1" }
    store:addMessage{ id = "b", title = "2", priority = "high" }
    store:addMessage{ id = "c", title = "3" }
    store:setRead("a", true)
    local first_read_at = store:getMessage("a").read_at
    store.on_change = function() changes = changes + 1 end
    eq(store:markAllRead(), 2, "changed")
    eq(store:unreadCount(), 0, "unread")
    eq(changes, 1, "change notifications")
    eq(store:getMessage("a").read_at, first_read_at, "already-read message touched")
    eq(store:markAllRead(), 0, "second call")
    eq(changes, 1, "a no-op still notified")
end)

test("a full inbox drops the oldest read message", function()
    local store = newStore()
    for i = 1, 100 do store:addMessage{ id = "m" .. i, title = "x" } end
    store:setRead("m5", true)
    store:setRead("m9", true)
    assert(store:addMessage{ id = "new", title = "x" }, "not added")
    eq(store:getMessage("m5"), nil, "oldest read")
    assert(store:getMessage("m9"), "newer read message removed")
    eq(#store.messages, 100, "count")
end)

test("a full inbox never drops unread messages", function()
    local store = newStore()
    for i = 1, 100 do store:addMessage{ id = "m" .. i, title = "x" } end
    local message, err = store:addMessage{ id = "new", title = "x" }
    eq(message, nil, "message")
    eq(err, "inbox_full", "error")
    eq(#store.messages, 100, "count")
end)

local function exists(path)
    local file = io.open(path, "r")
    if file then file:close() end
    return file ~= nil
end

test("a body is kept in its own file, with a preview in the index", function()
    local store = newStore()
    local body = "# Report\n\nAll **tests** passed.\n\n" .. string.rep("More detail. ", 20000)
    local message = store:addMessage{ id = "big", title = "Report", body = body }
    eq(message.body, nil, "body in index")
    eq(message.body_bytes, #body, "body_bytes")
    eq(message.preview:sub(1, 30), "Report All tests passed. More ", "preview")
    assert(#message.preview <= 200, "preview too long")
    eq(store:getBody(message), body, "body")
    assert(store:flush())
    local index = io.open(store.path):read("*a")
    assert(#index < 2000, "index holds the body: " .. #index)
end)

test("a message without a body has no file or preview", function()
    local store = newStore()
    local message = store:addMessage{ title = "Just a title" }
    eq(message.body_bytes, nil, "body_bytes")
    eq(message.preview, nil, "preview")
    eq(store:getBody(message), nil, "body")
end)

test("deleting or evicting a message removes its body file", function()
    local store = newStore()
    local deleted = store:addMessage{ id = "gone", title = "x", body = "text" }
    local deleted_path = store:_bodyPath(deleted)
    assert(exists(deleted_path), "body file missing")
    store:deleteMessage("gone")
    eq(exists(deleted_path), false, "deleted body file")

    local first = store:addMessage{ id = "m1", title = "x", body = "old" }
    local first_path = store:_bodyPath(first)
    store:setRead("m1", true)
    for i = 2, 100 do store:addMessage{ id = "m" .. i, title = "x" } end
    store:addMessage{ id = "new", title = "x" }
    eq(store:getMessage("m1"), nil, "evicted")
    eq(exists(first_path), false, "evicted body file")
end)

test("a body that can't be saved isn't added", function()
    local store = newStore{ body_dir = dir .. "/missing/deeper" }
    store.make_dir = function() end
    local message, err = store:addMessage{ title = "x", body = "text" }
    eq(message, nil, "message")
    eq(err, "storage_error", "error")
    eq(#store.messages, 0, "count")
    eq(store.next_seq, 1, "sequence reused")
end)

test("inline bodies from the earlier format move to files", function()
    local path = dir .. "/legacy.json"
    local file = io.open(path, "w")
    file:write('{"state":{},"next_seq":2,"messages":[{"id":"a","seq":1,"title":"Old","body":"**Hello** there","priority":"normal","received_at":5}]}')
    file:close()
    local store = newStore{ path = path }
    store:load()
    local message = store:getMessage("a")
    eq(message.body, nil, "inline body")
    eq(store:getBody(message), "**Hello** there", "body")
    eq(message.preview, "Hello there", "preview")
    eq(store.dirty, true, "needs saving")
end)

test("data survives a restart, including Chinese and awkward text", function()
    local path = dir .. "/restart.json"
    local store = newStore{ path = path }
    local awkward = 'os.execute("x") ]] "quoted" \\ 小雨\nline2'
    store:mergeState(patch('{"weather":{"summary":"18° 小雨"}}'))
    store:addMessage{ id = "a", title = awkward, body = awkward }
    assert(store:flush())

    local reloaded = newStore{ path = path }
    reloaded:load()
    eq(reloaded.state.weather.summary, "18° 小雨", "state")
    eq(reloaded:getMessage("a").title, awkward, "title")
    eq(reloaded:getBody(reloaded:getMessage("a")), awkward, "body")
    eq(reloaded.warning, nil, "warning")
    local message = reloaded:addMessage{ title = "next" }
    eq(message.seq, 2, "sequence continues")
end)

test("a corrupt file is set aside and the store starts empty", function()
    local path = dir .. "/corrupt.json"
    local file = io.open(path, "w")
    file:write("{not json")
    file:close()
    local store = newStore{ path = path }
    store:load()
    assert(store.warning, "no warning")
    eq(store:unreadCount(), 0, "unread")
    local moved = io.open(path .. ".bad", "r")
    assert(moved, "not set aside")
    moved:close()
end)

test("flush leaves no temporary file and skips when unchanged", function()
    local path = dir .. "/flush.json"
    local store = newStore{ path = path }
    store:mergeState(patch('{"a":1}'))
    assert(store:flush())
    eq(io.open(path .. ".tmp", "r"), nil, "temp file")
    eq(store.dirty, false, "dirty")
    assert(store:flush())
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

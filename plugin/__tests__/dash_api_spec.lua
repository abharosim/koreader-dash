-- Run: scripts/test.sh
package.path = "plugin/dash.koplugin/?.lua;" .. package.path
local json = require("json")
local Api = require("dash_api")
local Store = require("dash_store")

local dir = assert(os.getenv("KDASH_TEST_DIR"), "KDASH_TEST_DIR is required")
local TOKEN = "abcdefabcdefabcdefabcdefabcdefab"
local failures, passed = 0, 0

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

local setups = 0
local function setup()
    local clock = { now = 5000 }
    setups = setups + 1
    local store = Store.new{
        path = string.format("%s/api%d.json", dir, setups),
        body_dir = string.format("%s/api%d.bodies", dir, setups),
        make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
        now = function() return clock.now end,
    }
    local api = Api.new{ store = store, token = TOKEN, now = function() return clock.now end }
    return api, store, clock
end

local function call(api, method, path, body, token, query)
    local status, response = api:handle{
        method = method,
        path = path,
        query = query,
        body = body,
        headers = { authorization = "Bearer " .. (token or TOKEN) },
    }
    local decoded = response ~= "" and json.decode(response) or nil
    return status, decoded, response
end

test("/ping needs no token", function()
    local api = setup()
    local status = api:handle{ method = "GET", path = "/ping", headers = {} }
    eq(status, 200, "status")
end)

test("every other route needs the right token", function()
    local api = setup()
    for _, path in ipairs{ "/v1/state", "/v1/inbox", "/v1/health", "/v1/inbox/a", "/nope" } do
        eq(call(api, "GET", path, nil, "wrong"), 401, path)
        eq(api:handle{ method = "GET", path = path, headers = {} }, 401, path .. " no header")
    end
end)

test("PUT /v1/state merges and GET returns the blob", function()
    local api = setup()
    local status, body = call(api, "PUT", "/v1/state", '{"weather":{"summary":"Rain","detail":"Cold"}}')
    eq(status, 200, "status")
    eq(body.changed, true, "changed")
    call(api, "PUT", "/v1/state", '{"weather":{"summary":"Sun"}}')
    local _, state = call(api, "GET", "/v1/state")
    eq(state.weather.summary, "Sun", "summary")
    eq(state.weather.detail, "Cold", "detail")
end)

test("PUT /v1/state reports when nothing changed", function()
    local api = setup()
    call(api, "PUT", "/v1/state", '{"a":1}')
    local _, body = call(api, "PUT", "/v1/state", '{"a":1}')
    eq(body.changed, false, "changed")
end)

test("PUT /v1/state rejects invalid bodies", function()
    local api = setup()
    for _, bad in ipairs{ "", "{bad", "[1,2]", "3", '"text"', "null" } do
        local status, body = call(api, "PUT", "/v1/state", bad)
        eq(status, 400, "status for " .. bad)
        eq(body.error, "bad_json", "error for " .. bad)
    end
end)

test("rejects deeply nested JSON", function()
    local api = setup()
    local deep = string.rep('{"a":', 12) .. "1" .. string.rep("}", 12)
    eq(call(api, "PUT", "/v1/state", deep), 400, "status")
end)

test("POST /v1/inbox stores a full message", function()
    local api, store = setup()
    local status, body = call(api, "POST", "/v1/inbox",
        '{"id":"a1","type":"claude.permission","source":"mac","title":"Needs you 你好","body":"Details","priority":"high","data":{"session":"x"},"read_at":1}')
    eq(status, 201, "status")
    eq(body.id, "a1", "id")
    eq(body.unread, 1, "unread")
    local message = store:getMessage("a1")
    eq(message.title, "Needs you 你好", "title")
    eq(message.data.session, "x", "data")
    eq(message.read_at, nil, "client can't set read_at")
end)

test("POST /v1/inbox generates an id when none is given", function()
    local api = setup()
    local status, body = call(api, "POST", "/v1/inbox", '{"title":"Hi"}')
    eq(status, 201, "status")
    assert(body.id, "no id")
end)

test("a retried message returns 200 and isn't duplicated", function()
    local api, store = setup()
    call(api, "POST", "/v1/inbox", '{"id":"a","title":"Hi"}')
    local status, body = call(api, "POST", "/v1/inbox", '{"id":"a","title":"Hi"}')
    eq(status, 200, "status")
    eq(body.created, false, "created")
    eq(#store.messages, 1, "count")
end)

test("POST /v1/inbox validates each field", function()
    local api = setup()
    local cases = {
        "{}", '{"title":""}', '{"title":5}', '{"title":"x","body":5}',
        '{"title":"x","priority":"urgent"}', '{"title":"x","id":"bad id"}',
        '{"title":"x","data":"text"}', '{"title":"x","source":1}',
        json.encode({ title = string.rep("x", 301) }),
    }
    for _, body in ipairs(cases) do
        local status, decoded = call(api, "POST", "/v1/inbox", body)
        eq(status, 400, "status for " .. body:sub(1, 40))
        eq(decoded.error, "bad_field", "error for " .. body:sub(1, 40))
    end
end)

test("a full inbox returns 507", function()
    local api = setup()
    for i = 1, 100 do api.store:addMessage{ id = "m" .. i, title = "x" } end
    local status, body = call(api, "POST", "/v1/inbox", '{"title":"more"}')
    eq(status, 507, "status")
    eq(body.error, "inbox_full", "error")
end)

test("GET /v1/inbox lists without bodies and can filter unread", function()
    local api = setup()
    call(api, "POST", "/v1/inbox", json.encode({ id = "a", title = "One", body = string.rep("Long body. ", 100) .. "Secret ending" }))
    call(api, "POST", "/v1/inbox", '{"id":"b","title":"Two"}')
    call(api, "PUT", "/v1/inbox/a", '{"read":true}')
    local _, all, raw = call(api, "GET", "/v1/inbox")
    eq(#all.messages, 2, "all")
    eq(raw:find("Secret ending", 1, true), nil, "full body in list")
    local _, unread = call(api, "GET", "/v1/inbox", nil, nil, "unread=1")
    eq(#unread.messages, 1, "unread")
    eq(unread.messages[1].id, "b", "unread id")
end)

test("an empty inbox encodes messages as an array", function()
    local api = setup()
    local _, _, raw = call(api, "GET", "/v1/inbox")
    assert(raw:find('"messages":[]', 1, true), raw)
end)

test("accepts a 250 KB Markdown body and rejects anything over 256 KB", function()
    local api, store = setup()
    local body = string.rep("## Part\n\nText with **bold** and 小雨.\n\n", 6000):sub(1, 250 * 1024)
    local status = call(api, "POST", "/v1/inbox", json.encode({ id = "big", title = "Big", body = body }))
    eq(status, 201, "status")
    eq(store:getBody(store:getMessage("big")), body, "stored body")
    local too_big = string.rep("x", 256 * 1024 + 1)
    local rejected, decoded = call(api, "POST", "/v1/inbox", json.encode({ title = "Huge", body = too_big }))
    eq(rejected, 400, "oversized status")
    eq(decoded.error, "bad_field", "oversized error")
end)

test("the list includes a preview and size, but not the body", function()
    local api = setup()
    call(api, "POST", "/v1/inbox", '{"id":"a","title":"One","body":"# Heading\n\nThe **details**."}')
    local _, list, raw = call(api, "GET", "/v1/inbox")
    eq(list.messages[1].preview, "Heading The details.", "preview")
    eq(list.messages[1].body_bytes, 27, "body_bytes")
    eq(raw:find("**details**", 1, true), nil, "body in list")
end)

test("GET /v1/inbox/{id} returns the body", function()
    local api = setup()
    call(api, "POST", "/v1/inbox", '{"id":"a","title":"One","body":"Details"}')
    local status, message = call(api, "GET", "/v1/inbox/a")
    eq(status, 200, "status")
    eq(message.body, "Details", "body")
    eq(call(api, "GET", "/v1/inbox/missing"), 404, "missing")
end)

test("PUT /v1/inbox/{id} marks read and unread", function()
    local api, store = setup()
    call(api, "POST", "/v1/inbox", '{"id":"a","title":"One"}')
    local status, body = call(api, "PUT", "/v1/inbox/a", '{"read":true}')
    eq(status, 200, "status")
    eq(body.read_at, 5000, "read_at")
    eq(store:unreadCount(), 0, "unread")
    call(api, "PUT", "/v1/inbox/a", '{"read":false}')
    eq(store:unreadCount(), 1, "unread again")
    eq(call(api, "PUT", "/v1/inbox/a", '{"read":"yes"}'), 400, "bad value")
    eq(call(api, "PUT", "/v1/inbox/missing", '{"read":true}'), 404, "missing")
end)

test("DELETE /v1/inbox/{id} can be repeated", function()
    local api, store = setup()
    call(api, "POST", "/v1/inbox", '{"id":"a","title":"One"}')
    eq(call(api, "DELETE", "/v1/inbox/a"), 204, "first")
    eq(call(api, "DELETE", "/v1/inbox/a"), 204, "second")
    eq(#store.messages, 0, "count")
end)

test("wrong methods and paths are rejected", function()
    local api = setup()
    eq(call(api, "POST", "/v1/state", "{}"), 405, "state")
    eq(call(api, "DELETE", "/v1/inbox"), 405, "inbox")
    eq(call(api, "POST", "/v1/health"), 405, "health")
    eq(call(api, "POST", "/v1/inbox/a", "{}"), 405, "message")
    eq(call(api, "GET", "/v1/other"), 404, "unknown")
    eq(call(api, "GET", "/v1/inbox/bad%20id"), 400, "bad id")
end)

test("changes over the rate limit get 429, reads don't, and it resets", function()
    local api, _, clock = setup()
    for i = 1, 60 do
        eq(call(api, "PUT", "/v1/state", string.format('{"n":%d}', i)), 200, "change " .. i)
    end
    local status, body = call(api, "PUT", "/v1/state", '{"n":61}')
    eq(status, 429, "status")
    eq(body.retry_after, 60, "retry_after")
    eq(call(api, "GET", "/v1/state"), 200, "read")
    clock.now = clock.now + 60
    eq(call(api, "PUT", "/v1/state", '{"n":62}'), 200, "after reset")
end)

test("health reports unread count and device info", function()
    local api = setup()
    api.info = function() return { battery = 50 } end
    call(api, "POST", "/v1/inbox", '{"title":"One"}')
    local status, body = call(api, "GET", "/v1/health")
    eq(status, 200, "status")
    eq(body.battery, 50, "battery")
    eq(body.unread, 1, "unread")
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

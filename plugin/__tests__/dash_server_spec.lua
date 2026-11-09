-- Run: scripts/test.sh
-- Uses real loopback sockets, so split reads and partial writes behave as on the device.

local socket = require("socket")
local Server = dofile("plugin/dash.koplugin/dash_server.lua")

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

local function assertEq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function withServer(handler, fn)
    local server = Server.new({ host = "127.0.0.1", port = 0, handler = handler })
    assert(server:start())
    local ok, err = pcall(fn, server)
    server:stop()
    if not ok then error(err, 0) end
end

local function connect(server)
    local client = assert(socket.connect("127.0.0.1", server.port))
    client:settimeout(0)
    return client
end

-- Pumps the server until the client sees the connection close.
local function readResponse(server, client, max_seconds)
    local deadline = socket.gettime() + (max_seconds or 2)
    local received = ""
    while socket.gettime() < deadline do
        server:poll()
        local data, err, partial = client:receive(65536)
        received = received .. (data or partial or "")
        if err == "closed" then
            return received
        end
        socket.sleep(0.001)
    end
    return received, "client timeout"
end

local function statusOf(response)
    return tonumber(response:match("^HTTP/1%.1 (%d+)"))
end

local function pingHandler()
    return 200, '{"ok":true}'
end

test("answers a simple GET", function()
    withServer(pingHandler, function(server)
        local client = connect(server)
        client:send("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n")
        local response = readResponse(server, client)
        assertEq(statusOf(response), 200, "status")
        assert(response:find('{"ok":true}', 1, true), "body missing")
        assert(response:find("Connection: close", 1, true), "close header missing")
    end)
end)

test("parses method, path, query and headers", function()
    local seen
    withServer(function(request) seen = request; return 200, "" end, function(server)
        local client = connect(server)
        client:send("GET /v1/x?a=1 HTTP/1.1\r\nAuthorization: Bearer abc\r\n\r\n")
        readResponse(server, client)
    end)
    assertEq(seen.method, "GET", "method")
    assertEq(seen.path, "/v1/x", "path")
    assertEq(seen.query, "a=1", "query")
    assertEq(seen.headers.authorization, "Bearer abc", "authorization")
end)

test("regression: accepts a request with no headers", function()
    withServer(pingHandler, function(server)
        local client = connect(server)
        client:send("GET /ping HTTP/1.1\r\n\r\n")
        assertEq(statusOf(readResponse(server, client)), 200, "status")
    end)
end)

test("regression: a colon in the URL isn't read as a header", function()
    local seen
    withServer(function(request) seen = request; return 200, "" end, function(server)
        local client = connect(server)
        client:send("GET /a:b HTTP/1.1\r\nHost: x\r\n\r\n")
        readResponse(server, client)
    end)
    assertEq(seen.path, "/a:b", "path")
    assertEq(seen.headers.a, nil, "spurious header")
end)

test("reassembles a request split across reads", function()
    local body_seen
    withServer(function(request) body_seen = request.body; return 200, "" end, function(server)
        local client = connect(server)
        client:send("PUT /x HTTP/1.1\r\nContent-Le")
        server:poll(); socket.sleep(0.01); server:poll()
        client:send("ngth: 5\r\n\r\nhe")
        server:poll(); socket.sleep(0.01); server:poll()
        client:send("llo")
        assertEq(statusOf(readResponse(server, client)), 200, "status")
    end)
    assertEq(body_seen, "hello", "body")
end)

test("preserves UTF-8 bodies", function()
    local body_seen
    local text = "18° 小雨"
    withServer(function(request) body_seen = request.body; return 200, "" end, function(server)
        local client = connect(server)
        client:send("PUT /x HTTP/1.1\r\nContent-Length: " .. #text .. "\r\n\r\n" .. text)
        readResponse(server, client)
    end)
    assertEq(body_seen, text, "body")
end)

test("answers Expect: 100-continue before the body arrives", function()
    withServer(pingHandler, function(server)
        local client = connect(server)
        client:send("PUT /x HTTP/1.1\r\nContent-Length: 2\r\nExpect: 100-continue\r\n\r\n")
        local deadline = socket.gettime() + 1
        local received = ""
        while socket.gettime() < deadline and not received:find("100 Continue", 1, true) do
            server:poll()
            local data, _, partial = client:receive(1024)
            received = received .. (data or partial or "")
            socket.sleep(0.001)
        end
        assert(received:find("100 Continue", 1, true), "no interim response")
        client:send("ok")
        local response = received .. readResponse(server, client)
        assert(response:find("200 OK", 1, true), "no final response")
    end)
end)

test("rejects oversized headers with 413", function()
    withServer(pingHandler, function(server)
        local client = connect(server)
        client:send("GET /x HTTP/1.1\r\nX-Pad: " .. string.rep("a", 9000))
        assertEq(statusOf(readResponse(server, client)), 413, "status")
    end)
end)

test("rejects oversized bodies with 413 without calling the handler", function()
    local called = false
    withServer(function() called = true; return 200, "" end, function(server)
        local client = connect(server)
        client:send("PUT /x HTTP/1.1\r\nContent-Length: 400000\r\n\r\n")
        assertEq(statusOf(readResponse(server, client)), 413, "status")
    end)
    assertEq(called, false, "handler called")
end)

test("receives a 300 KB body sent in pieces", function()
    local body_seen
    local body = string.rep("0123456789", 30 * 1024)
    withServer(function(request) body_seen = request.body; return 200, "" end, function(server)
        local client = connect(server)
        client:settimeout(1)
        client:send("PUT /x HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n")
        local sent, deadline = 0, socket.gettime() + 3
        while sent < #body and socket.gettime() < deadline do
            local last, _, partial = client:send(body, sent + 1, math.min(sent + 65536, #body))
            sent = last or partial or sent
            server:poll()
        end
        client:settimeout(0)
        assertEq(statusOf(readResponse(server, client, 3)), 200, "status")
    end)
    assertEq(body_seen and #body_seen, #body, "body length")
end)

test("rejects chunked uploads with 411", function()
    withServer(pingHandler, function(server)
        local client = connect(server)
        client:send("PUT /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
        assertEq(statusOf(readResponse(server, client)), 411, "status")
    end)
end)

test("rejects malformed requests with 400", function()
    withServer(pingHandler, function(server)
        local client = connect(server)
        client:send("not http at all\r\n\r\n")
        assertEq(statusOf(readResponse(server, client)), 400, "status")
    end)
end)

test("returns 500 when the handler raises an error", function()
    withServer(function() error("boom") end, function(server)
        local client = connect(server)
        client:send("GET /x HTTP/1.1\r\n\r\n")
        assertEq(statusOf(readResponse(server, client)), 500, "status")
    end)
end)

test("returns 503 past the connection limit", function()
    withServer(pingHandler, function(server)
        local idle = {}
        for i = 1, 4 do
            idle[i] = connect(server)
        end
        socket.sleep(0.01)
        server:poll()
        local extra = connect(server)
        assertEq(statusOf(readResponse(server, extra)), 503, "status")
    end)
end)

test("a stalled client doesn't block poll", function()
    withServer(pingHandler, function(server)
        local stalled = connect(server)
        stalled:send("GET /x HTTP/1.1\r\nHost")
        local started = socket.gettime()
        for _ = 1, 100 do
            server:poll()
        end
        assert(socket.gettime() - started < 0.05, "poll blocked")
        local client = connect(server)
        client:send("GET /x HTTP/1.1\r\n\r\n")
        assertEq(statusOf(readResponse(server, client)), 200, "other client status")
    end)
end)

test("sends a response larger than the socket buffer", function()
    local large = string.rep("x", 4 * 1024 * 1024)
    withServer(function() return 200, large end, function(server)
        local client = connect(server)
        client:send("GET /x HTTP/1.1\r\n\r\n")
        local response, err = readResponse(server, client, 2.5)
        assertEq(err, nil, "read error")
        assert(response:sub(-#large) == large, "body truncated: " .. #response)
    end)
end)

test("can stop and start again on the same port", function()
    local server = Server.new({ host = "127.0.0.1", port = 0, handler = pingHandler })
    assert(server:start())
    local port = server.port
    server:stop()
    assertEq(server:isRunning(), false, "running after stop")
    server.port = port
    assert(server:start())
    local client = connect(server)
    client:send("GET /x HTTP/1.1\r\n\r\n")
    assertEq(statusOf(readResponse(server, client)), 200, "status")
    server:stop()
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

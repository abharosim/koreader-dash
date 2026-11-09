-- Minimal non-blocking HTTP/1.1 server. Call poll() repeatedly.
-- Has no KOReader imports, so it can be tested with plain LuaJIT and LuaSocket.
-- Files use a dash_ prefix because plugin modules share one global require() namespace.

local socket = require("socket")

local MAX_CONNECTIONS = 4
local CONNECTION_DEADLINE_SECONDS = 10
local MAX_HEADER_BYTES = 8 * 1024
local MAX_BODY_BYTES = 320 * 1024
local READ_CHUNK_BYTES = 16 * 1024
local MAX_READS_PER_POLL = 32

local REASONS = {
    [100] = "Continue", [200] = "OK", [201] = "Created", [204] = "No Content", [400] = "Bad Request",
    [401] = "Unauthorized", [404] = "Not Found", [405] = "Method Not Allowed",
    [411] = "Length Required", [413] = "Payload Too Large", [429] = "Too Many Requests",
    [500] = "Internal Server Error", [503] = "Service Unavailable", [507] = "Insufficient Storage",
}

local function encodeResponse(status, body)
    body = body or ""
    return table.concat({
        "HTTP/1.1 ", status, " ", REASONS[status] or "Unknown", "\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", #body, "\r\n",
        "Connection: close\r\n\r\n",
        body,
    })
end

local function errorBody(code)
    return string.format('{"error":"%s"}', code)
end

local function parseHead(head)
    local method, target, header_start = head:match("^(%u+) (%S+) HTTP/1%.[01]\r?\n()")
    if not method then
        return nil
    end
    local headers = {}
    for name, value in head:sub(header_start):gmatch("([%w%-]+):[ \t]*([^\r\n]*)") do
        headers[name:lower()] = value
    end
    return {
        method = method,
        path = target:match("^[^?]*"),
        query = target:match("%?(.*)$"),
        headers = headers,
    }
end

local Server = {}
Server.__index = Server

-- opts: host (default "*"), port (required),
--       handler(request) -> status, body
function Server.new(opts)
    return setmetatable({
        host = opts.host or "*",
        port = opts.port,
        handler = opts.handler,
        connections = {},
        listener = nil,
    }, Server)
end

function Server:start()
    if self.listener then
        return true
    end
    local listener, err = socket.bind(self.host, self.port)
    if not listener then
        return false, err
    end
    listener:settimeout(0)
    self.listener = listener
    if not self.port or self.port == 0 then
        local _, bound_port = listener:getsockname()
        self.port = tonumber(bound_port)
    end
    return true
end

function Server:stop()
    for _, conn in ipairs(self.connections) do
        conn.sock:close()
    end
    self.connections = {}
    if self.listener then
        self.listener:close()
        self.listener = nil
    end
end

function Server:isRunning()
    return self.listener ~= nil
end

function Server:_respond(conn, status, body)
    conn.outgoing = encodeResponse(status, body)
    conn.sent = 0
end

function Server:_dispatch(conn, body)
    local request = conn.request
    request.body = body
    local ok, status, response_body = pcall(self.handler, request)
    if ok then
        self:_respond(conn, status, response_body)
    else
        self:_respond(conn, 500, errorBody("internal"))
    end
end

-- Returns once the request is complete or more data is needed.
function Server:_parse(conn)
    if not conn.request then
        local head_end, body_start = conn.buffer:find("\r?\n\r?\n")
        if not head_end then
            if #conn.buffer > MAX_HEADER_BYTES then
                self:_respond(conn, 413, errorBody("too_large"))
            end
            return
        end
        if head_end > MAX_HEADER_BYTES then
            self:_respond(conn, 413, errorBody("too_large"))
            return
        end
        local request = parseHead(conn.buffer:sub(1, body_start))
        if not request then
            self:_respond(conn, 400, errorBody("bad_request"))
            return
        end
        conn.request = request
        conn.buffer = conn.buffer:sub(body_start + 1)

        local headers = request.headers
        if headers["transfer-encoding"] then
            self:_respond(conn, 411, errorBody("length_required"))
            return
        end
        local declared = headers["content-length"]
        local length = tonumber(declared or "0")
        if not length or length < 0 or length ~= math.floor(length) then
            self:_respond(conn, 400, errorBody("bad_request"))
            return
        end
        if length > MAX_BODY_BYTES then
            self:_respond(conn, 413, errorBody("too_large"))
            return
        end
        conn.body_length = length

        if (headers["expect"] or ""):lower() == "100-continue" and #conn.buffer < length then
            -- curl otherwise waits about a second before sending the body.
            conn.sock:send("HTTP/1.1 100 Continue\r\n\r\n")
        end
    end

    if #conn.buffer >= conn.body_length then
        self:_dispatch(conn, conn.buffer:sub(1, conn.body_length))
    end
end

-- Returns true when the connection is finished and should be closed.
function Server:_step(conn, now)
    if now > conn.deadline then
        return true
    end

    if conn.outgoing then
        local last, err, partial_last = conn.sock:send(conn.outgoing, conn.sent + 1)
        local sent_to = last or partial_last or conn.sent
        conn.sent = sent_to
        if conn.sent >= #conn.outgoing then
            return true
        end
        return err ~= nil and err ~= "timeout"
    end

    -- Read everything waiting, so a large body doesn't take one poll per chunk.
    local chunks, closed = {}, false
    for _ = 1, MAX_READS_PER_POLL do
        local data, err, partial = conn.sock:receive(READ_CHUNK_BYTES)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            table.insert(chunks, chunk)
        end
        if err then
            closed = err ~= "timeout"
            break
        end
    end
    if #chunks > 0 then
        conn.buffer = conn.buffer .. table.concat(chunks)
        self:_parse(conn)
        if conn.outgoing then
            return self:_step(conn, now)
        end
    end
    return closed
end

-- Handles all pending work without blocking.
function Server:poll()
    if not self.listener then
        return
    end
    local now = socket.gettime()

    while true do
        local client = self.listener:accept()
        if not client then
            break
        end
        client:settimeout(0)
        local conn = { sock = client, buffer = "", deadline = now + CONNECTION_DEADLINE_SECONDS }
        if #self.connections >= MAX_CONNECTIONS then
            self:_respond(conn, 503, errorBody("busy"))
        end
        table.insert(self.connections, conn)
    end

    for i = #self.connections, 1, -1 do
        local conn = self.connections[i]
        if self:_step(conn, now) then
            conn.sock:close()
            table.remove(self.connections, i)
        end
    end
end

return Server

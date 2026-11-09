-- HTTP routes, auth and validation. See SPEC.md, "HTTP API".
-- Has no KOReader imports. handle(request) returns status, body.

local json = require("json")

local MAX_CHANGES_PER_MINUTE = 60
local MAX_DEPTH = 8
local PRIORITIES = { low = true, normal = true, high = true }
local STRING_LIMITS = { title = 300, body = 256 * 1024, source = 64, type = 64 }

local function reply(status, value)
    return status, json.encode(value)
end

local function fail(status, code, message)
    return reply(status, { error = code, message = message })
end

local function validId(id)
    return type(id) == "string" and #id >= 1 and #id <= 64 and id:match("^[%w%._:%-]+$") ~= nil
end

local function depthWithin(value, limit)
    if type(value) ~= "table" then
        return true
    end
    if limit == 0 then
        return false
    end
    for _, child in pairs(value) do
        if not depthWithin(child, limit - 1) then
            return false
        end
    end
    return true
end

-- Returns the decoded object, or nil plus a ready-made error response.
local function readObject(request)
    local ok, value = pcall(json.decode, request.body or "")
    if not ok or type(value) ~= "table" or #value > 0 then
        return nil, 400, json.encode({ error = "bad_json", message = "Body must be a JSON object" })
    end
    if not depthWithin(value, MAX_DEPTH) then
        return nil, 400, json.encode({ error = "bad_json", message = "JSON is nested too deeply" })
    end
    return value
end

local function validateMessage(body)
    if type(body.title) ~= "string" or body.title == "" then
        return "title is required"
    end
    for field, limit in pairs(STRING_LIMITS) do
        local value = body[field]
        if value ~= nil then
            if type(value) ~= "string" then
                return field .. " must be a string"
            end
            if #value > limit then
                return string.format("%s is over %d bytes", field, limit)
            end
        end
    end
    if body.priority ~= nil and not PRIORITIES[body.priority] then
        return "priority must be low, normal or high"
    end
    if body.id ~= nil and not validId(body.id) then
        return "id must be 1 to 64 letters, digits or . _ : -"
    end
    if body.data ~= nil and type(body.data) ~= "table" then
        return "data must be an object or array"
    end
    return nil
end

local function summary(message)
    return {
        id = message.id,
        type = message.type,
        source = message.source,
        title = message.title,
        priority = message.priority,
        preview = message.preview,
        body_bytes = message.body_bytes,
        received_at = message.received_at,
        read_at = message.read_at,
    }
end

local Api = {}
Api.__index = Api

-- opts: store, token, now (optional), info (optional function returning health fields),
--       on_ping (optional callback)
function Api.new(opts)
    return setmetatable({
        store = opts.store,
        token = opts.token,
        now = opts.now or os.time,
        info = opts.info,
        on_ping = opts.on_ping,
        window_start = 0,
        window_changes = 0,
    }, Api)
end

function Api:_authorized(request)
    return (request.headers.authorization or "") == "Bearer " .. self.token
end

function Api:_overRateLimit()
    local now = self.now()
    if now - self.window_start >= 60 then
        self.window_start = now
        self.window_changes = 0
    end
    self.window_changes = self.window_changes + 1
    return self.window_changes > MAX_CHANGES_PER_MINUTE
end

function Api:_health()
    local fields = self.info and self.info() or {}
    fields.ok = true
    fields.time = self.now()
    fields.unread = self.store:unreadCount()
    return reply(200, fields)
end

function Api:_putState(request)
    local patch, status, body = readObject(request)
    if not patch then
        return status, body
    end
    local changed, err = self.store:mergeState(patch)
    if changed == nil then
        return fail(413, err, "State is over the 64 KB limit")
    end
    return reply(200, { changed = changed })
end

function Api:_postMessage(request)
    local fields, status, body = readObject(request)
    if not fields then
        return status, body
    end
    local problem = validateMessage(fields)
    if problem then
        return fail(400, "bad_field", problem)
    end
    local message, created = self.store:addMessage(fields)
    if not message then
        if created == "inbox_full" then
            return fail(507, created, "The inbox is full of unread messages")
        end
        return fail(500, created, "Couldn't save the message")
    end
    return reply(created and 201 or 200, {
        id = message.id,
        created = created,
        unread = self.store:unreadCount(),
    })
end

function Api:_listMessages(request)
    local only_unread = (request.query or ""):match("^unread=1$") ~= nil
    local list = {}
    local source = only_unread and self.store:unreadMessages() or self.store.messages
    for _, message in ipairs(source) do
        table.insert(list, summary(message))
    end
    -- Stops an empty list being encoded as an object.
    if #list == 0 then
        return 200, '{"messages":[],"unread":0}'
    end
    return reply(200, { messages = list, unread = self.store:unreadCount() })
end

function Api:_putMessage(request, id)
    local fields, status, body = readObject(request)
    if not fields then
        return status, body
    end
    if type(fields.read) ~= "boolean" then
        return fail(400, "bad_field", "read must be true or false")
    end
    local message = self.store:setRead(id, fields.read)
    if not message then
        return fail(404, "not_found", "No such message")
    end
    return reply(200, summary(message))
end

local function methodNotAllowed()
    return fail(405, "method_not_allowed", "That method isn't supported here")
end

function Api:_route(request)
    local method, path = request.method, request.path
    local is_change = method ~= "GET"

    if is_change and self:_overRateLimit() then
        return reply(429, { error = "rate_limited", message = "Too many changes", retry_after = 60 })
    end

    if path == "/v1/health" then
        if method ~= "GET" then return methodNotAllowed() end
        return self:_health()
    end
    if path == "/v1/state" then
        if method == "GET" then return reply(200, self.store.state) end
        if method == "PUT" then return self:_putState(request) end
        return methodNotAllowed()
    end
    if path == "/v1/inbox" then
        if method == "GET" then return self:_listMessages(request) end
        if method == "POST" then return self:_postMessage(request) end
        return methodNotAllowed()
    end

    local id = path:match("^/v1/inbox/([^/]+)$")
    if id then
        if not validId(id) then
            return fail(400, "bad_id", "Invalid message id")
        end
        if method == "DELETE" then
            self.store:deleteMessage(id)
            return 204, ""
        end
        if method == "PUT" then
            return self:_putMessage(request, id)
        end
        if method == "GET" then
            local message = self.store:getMessage(id)
            if not message then
                return fail(404, "not_found", "No such message")
            end
            local full = summary(message)
            full.data = message.data
            full.body = self.store:getBody(message)
            return reply(200, full)
        end
        return methodNotAllowed()
    end
    return fail(404, "not_found", "Unknown path")
end

function Api:handle(request)
    -- /ping needs no token and reveals nothing private, so it can check connectivity.
    if request.path == "/ping" then
        if request.method ~= "GET" then
            return methodNotAllowed()
        end
        if self.on_ping then
            self.on_ping()
        end
        return reply(200, { ok = true, time = self.now() })
    end
    if not self:_authorized(request) then
        return fail(401, "unauthorized", "Missing or wrong token")
    end
    return self:_route(request)
end

return Api

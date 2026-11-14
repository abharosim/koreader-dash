-- The dashboard's data: one JSON state blob and an inbox queue of messages.
-- Message bodies can be large, so each lives in its own file and the index holds a preview.
-- Has no KOReader imports. Data is saved as JSON so network text is never run as code.

local json = require("json")
local Markdown = require("dash_markdown")

local MAX_MESSAGES = 100
local MAX_STATE_BYTES = 64 * 1024

local function isObject(value)
    return type(value) == "table" and #value == 0
end

local function deepEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not deepEqual(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

-- RFC 7386 JSON Merge Patch: objects merge, null removes, anything else replaces.
-- Returns a new table, so the original is untouched if the result is later rejected.
local function mergePatch(target, patch)
    if not isObject(patch) then
        return patch
    end
    local result = {}
    if isObject(target) then
        for key, value in pairs(target) do
            result[key] = value
        end
    end
    for key, value in pairs(patch) do
        if value == json.util.null then
            result[key] = nil
        else
            result[key] = mergePatch(result[key], value)
        end
    end
    return result
end

local Store = {}
Store.__index = Store

local PREVIEW_BYTES = 200

local function writeFileAtomically(path, content)
    local temp_path = path .. ".tmp"
    local file, err = io.open(temp_path, "wb")
    if not file then
        return false, err
    end
    file:write(content)
    file:close()
    return os.rename(temp_path, path)
end

-- opts: path and body_dir (required), make_dir (function creating a directory),
--       now (optional clock function), on_change (optional callback)
function Store.new(opts)
    return setmetatable({
        path = opts.path,
        body_dir = opts.body_dir,
        make_dir = opts.make_dir,
        now = opts.now or os.time,
        on_change = opts.on_change,
        state = {},
        messages = {},
        next_seq = 1,
        dirty = false,
        warning = nil,
    }, Store)
end

function Store:_changed()
    self.dirty = true
    if self.on_change then
        self.on_change()
    end
end

function Store:_bodyPath(message)
    return string.format("%s/%d.md", self.body_dir, message.seq)
end

-- Body files are named by sequence number, as ids may contain characters the Kindle's
-- filesystem rejects. A crash before the index is saved can leave a file behind, but the
-- next message with that number overwrites it.
function Store:_writeBody(message, body)
    if not self.body_dir_ready then
        self.make_dir(self.body_dir)
        self.body_dir_ready = true
    end
    return writeFileAtomically(self:_bodyPath(message), body)
end

function Store:getBody(message)
    if not message.body_bytes then
        return nil
    end
    local file = io.open(self:_bodyPath(message), "rb")
    if not file then
        return nil
    end
    local body = file:read("*a")
    file:close()
    return body
end

function Store:_removeBody(message)
    if message.body_bytes then
        os.remove(self:_bodyPath(message))
    end
end

function Store:load()
    local file = io.open(self.path, "r")
    if not file then
        return
    end
    local content = file:read("*a")
    file:close()

    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" and isObject(data.state) and type(data.messages) == "table" then
        self.state = data.state
        self.messages = data.messages
        self.next_seq = tonumber(data.next_seq) or 1
        -- Earlier versions kept bodies inline.
        for _, message in ipairs(self.messages) do
            if type(message.body) == "string" then
                local body = message.body
                message.body = nil
                if self:_writeBody(message, body) then
                    message.body_bytes = #body
                    message.preview = Markdown.preview(body, PREVIEW_BYTES)
                    self.dirty = true
                end
            end
        end
    else
        os.rename(self.path, self.path .. ".bad")
        self.warning = "Saved data was unreadable and has been reset"
    end
end

-- Writes to a temporary file first, so a crash can't leave a half-written file.
function Store:flush()
    if not self.dirty then
        return true
    end
    local ok, err = writeFileAtomically(self.path,
        json.encode({ state = self.state, messages = self.messages, next_seq = self.next_seq }))
    if not ok then
        return false, err
    end
    self.dirty = false
    return true
end

-- Returns whether anything changed, or nil and an error code.
function Store:mergeState(patch)
    local merged = mergePatch(self.state, patch)
    if #json.encode(merged) > MAX_STATE_BYTES then
        return nil, "state_too_large"
    end
    if deepEqual(self.state, merged) then
        return false
    end
    self.state = merged
    self:_changed()
    return true
end

function Store:getMessage(id)
    for index, message in ipairs(self.messages) do
        if message.id == id then
            return message, index
        end
    end
    return nil
end

function Store:_removeOldestRead()
    for index, message in ipairs(self.messages) do
        if message.read_at then
            self:_removeBody(message)
            table.remove(self.messages, index)
            return true
        end
    end
    return false
end

-- Returns the message and whether it was newly added, or nil and an error code.
-- Unread messages are never dropped to make room.
function Store:addMessage(fields)
    if fields.id then
        local existing = self:getMessage(fields.id)
        if existing then
            return existing, false -- A retry, so a message already read stays read.
        end
    end
    if #self.messages >= MAX_MESSAGES and not self:_removeOldestRead() then
        return nil, "inbox_full"
    end

    local now = self.now()
    local seq = self.next_seq
    self.next_seq = seq + 1
    local message = {
        id = fields.id or string.format("m%d-%d", now, seq),
        seq = seq,
        type = fields.type,
        source = fields.source,
        title = fields.title,
        priority = fields.priority or "normal",
        data = fields.data,
        received_at = now,
    }
    if type(fields.body) == "string" and fields.body ~= "" then
        local ok, err = self:_writeBody(message, fields.body)
        if not ok then
            self.next_seq = seq
            return nil, "storage_error", err
        end
        message.body_bytes = #fields.body
        message.preview = Markdown.preview(fields.body, PREVIEW_BYTES)
    end
    table.insert(self.messages, message)
    self:_changed()
    return message, true
end

function Store:setRead(id, read)
    local message = self:getMessage(id)
    if not message then
        return nil
    end
    if (message.read_at ~= nil) ~= read then
        message.read_at = read and self.now() or nil
        self:_changed()
    end
    return message
end

-- Marks every unread message read. Returns how many changed.
function Store:markAllRead()
    local now, count = self.now(), 0
    for _, message in ipairs(self.messages) do
        if not message.read_at then
            message.read_at = now
            count = count + 1
        end
    end
    if count > 0 then
        self:_changed()
    end
    return count
end

function Store:deleteMessage(id)
    local message, index = self:getMessage(id)
    if message then
        self:_removeBody(message)
        table.remove(self.messages, index)
        self:_changed()
    end
end

function Store:unreadCount()
    local count = 0
    for _, message in ipairs(self.messages) do
        if not message.read_at then
            count = count + 1
        end
    end
    return count
end

-- Oldest first, as a queue, with high priority ahead of everything else.
function Store:unreadMessages()
    local unread = {}
    for _, message in ipairs(self.messages) do
        if not message.read_at then
            table.insert(unread, message)
        end
    end
    table.sort(unread, function(a, b)
        local a_high, b_high = a.priority == "high", b.priority == "high"
        if a_high ~= b_high then
            return a_high
        end
        return a.seq < b.seq
    end)
    return unread
end

return Store

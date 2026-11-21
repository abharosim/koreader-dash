-- Audi history. Bodies live in their own files, named by sequence number, so an id can contain ":".
-- The HTTP inbox never includes these entries. The dash home list reads them from here.
-- Has no KOReader imports. Saved as JSON so network text is never run as code.
--
-- read_at is set when that entry is shown in Audi fullscreen. inbox_hidden is set by
-- action: clear so those rows leave the home list; the archive itself stays.
-- read_state 1 means read_at has been stored. Older files are migrated on load.

local json = require("json")
local Markdown = require("dash_markdown")
local Time = require("dash_time")

local AudiStore = {}
AudiStore.__index = AudiStore
AudiStore.HISTORY_LIMIT = 20

local PREVIEW_BYTES = 200
local DAY = 86400

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

-- "1970-01-01T00:00:00Z" or "1970-01-01T00:00:00-05:00" -> unix seconds.
-- Returns nil when the text isn't a flat ISO 8601 timestamp.
local function parseIso8601(text)
    if type(text) ~= "string" then
        return nil
    end
    local year, month, day, hour, min, sec, zone = text:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
    if not year then
        return nil
    end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, min, sec = tonumber(hour), tonumber(min), tonumber(sec)
    if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or min > 59 or sec > 60 then
        return nil
    end
    local offset = 0
    if zone ~= "Z" and zone ~= "z" and zone ~= "" then
        local sign, oh, om = zone:match("^([%+%-])(%d%d):?(%d%d)$")
        if not sign then
            return nil
        end
        offset = (tonumber(oh) * 60 + tonumber(om)) * 60
        if sign == "-" then
            offset = -offset
        end
    end
    local local_unix = Time.daysFromCivil(year, month, day) * DAY + hour * 3600 + min * 60 + sec
    return local_unix - offset
end

-- opts: path and body_dir (required), make_dir (function), now, limit, on_change.
function AudiStore.new(opts)
    return setmetatable({
        path = opts.path,
        body_dir = opts.body_dir,
        make_dir = opts.make_dir,
        now = opts.now or os.time,
        limit = opts.limit or AudiStore.HISTORY_LIMIT,
        on_change = opts.on_change,
        entries = {},
        next_seq = 1,
        next_ref = 1,
        current_id = nil,
        pending_show = false,
        unseen = 0,
        read_state = 1,
        dirty = false,
        warning = nil,
    }, AudiStore)
end

function AudiStore:_touch(info)
    self.dirty = true
    if self.on_change then
        self.on_change(info)
    end
end

-- The Audi button badge. Hidden rows are off the home list, so they don't count.
function AudiStore:_syncUnseen()
    local count = 0
    for _, entry in ipairs(self.entries) do
        if not entry.read_at and not entry.inbox_hidden then
            count = count + 1
        end
    end
    self.unseen = count
end

function AudiStore:_bodyPath(entry)
    return string.format("%s/%d.md", self.body_dir, entry.seq)
end

function AudiStore:_writeBody(entry, body)
    if not self.body_dir_ready then
        self.make_dir(self.body_dir)
        self.body_dir_ready = true
    end
    return writeFileAtomically(self:_bodyPath(entry), body)
end

function AudiStore:getBody(entry)
    if not entry or not entry.body_bytes then
        return nil
    end
    local file = io.open(self:_bodyPath(entry), "rb")
    if not file then
        return nil
    end
    local body = file:read("*a")
    file:close()
    return body
end

function AudiStore:_removeBody(entry)
    if entry.body_bytes then
        os.remove(self:_bodyPath(entry))
    end
end

function AudiStore:get(id)
    for index, entry in ipairs(self.entries) do
        if entry.id == id then
            return entry, index
        end
    end
    return nil
end

function AudiStore:current()
    if not self.current_id then
        return nil
    end
    return self:get(self.current_id)
end

function AudiStore:currentRef()
    local entry = self:current()
    return entry and entry.ref or nil
end

function AudiStore:_assignRef(ref)
    if type(ref) == "number" and ref >= 1 and ref == math.floor(ref) and ref < 1e15 then
        if ref >= self.next_ref then
            self.next_ref = ref + 1
        end
        return ref
    end
    local assigned = self.next_ref
    self.next_ref = assigned + 1
    return assigned
end

function AudiStore:_applyTime(entry, created_at, now)
    if type(created_at) == "string" and created_at ~= "" then
        entry.created_at = created_at
        entry.display_at = parseIso8601(created_at) or now
    else
        entry.created_at = nil
        entry.display_at = now
    end
end

function AudiStore:_setBody(entry, body)
    if body ~= "" then
        local ok, err = self:_writeBody(entry, body)
        if not ok then
            return false, err
        end
        entry.body_bytes = #body
        entry.preview = Markdown.preview(body, PREVIEW_BYTES)
    else
        self:_removeBody(entry)
        entry.body_bytes = nil
        entry.preview = nil
    end
    return true
end

function AudiStore:_sameContent(entry, title, body)
    if (entry.title or "") ~= title then
        return false
    end
    return (self:getBody(entry) or "") == body
end

function AudiStore:_dropOldest()
    local oldest = table.remove(self.entries, 1)
    if oldest then
        self:_removeBody(oldest)
        if self.current_id == oldest.id then
            self.current_id = nil
        end
    end
end

-- Returns the entry and a result table, or nil and "storage_error".
-- A clear returns nil and { cleared = true } without adding a row.
function AudiStore:submit(fields)
    if fields.action == "clear" then
        return self:clear()
    end
    local title = fields.title or ""
    local body = fields.body or ""
    local target = nil
    if fields.replace_id then
        target = self:get(fields.replace_id)
    end
    if not target and fields.id then
        target = self:get(fields.id)
    end
    if target then
        if self:_sameContent(target, title, body) then
            return target, { created = false, updated = false, cleared = false }
        end
        return self:_update(target, fields, title, body)
    end
    return self:_create(fields, title, body)
end

function AudiStore:_create(fields, title, body)
    while #self.entries >= self.limit do
        self:_dropOldest()
    end
    local now = self.now()
    local seq = self.next_seq
    self.next_seq = seq + 1
    local entry = {
        id = fields.id or string.format("a%d-%d", now, seq),
        seq = seq,
        ref = self:_assignRef(fields.ref),
        title = title,
        source = (type(fields.source) == "string" and fields.source ~= "") and fields.source or "Audi",
        received_at = now,
    }
    self:_applyTime(entry, fields.created_at, now)
    local ok, err = self:_setBody(entry, body)
    if not ok then
        self.next_seq = seq
        return nil, "storage_error", err
    end
    table.insert(self.entries, entry)
    self.current_id = entry.id
    self.pending_show = true
    self:_syncUnseen()
    self:_touch({ kind = "created", show = true, id = entry.id })
    return entry, { created = true, updated = false, cleared = false }
end

function AudiStore:_update(entry, fields, title, body)
    local now = self.now()
    entry.title = title
    if type(fields.source) == "string" and fields.source ~= "" then
        entry.source = fields.source
    end
    entry.received_at = now
    -- A new body is unread again, and clear no longer keeps it off the home list.
    entry.read_at = nil
    entry.inbox_hidden = nil
    if fields.created_at ~= nil then
        self:_applyTime(entry, fields.created_at, now)
    else
        entry.created_at = nil
        entry.display_at = now
    end
    local ok, err = self:_setBody(entry, body)
    if not ok then
        return nil, "storage_error", err
    end
    self.current_id = entry.id
    self.pending_show = true
    self:_syncUnseen()
    self:_touch({ kind = "updated", show = true, id = entry.id })
    return entry, { created = false, updated = true, cleared = false }
end

function AudiStore:clear()
    local changed = self.current_id ~= nil or self.pending_show or self.unseen ~= 0
    self.current_id = nil
    self.pending_show = false
    -- The archive stays. The home list drops every row until a later create or update.
    for _, entry in ipairs(self.entries) do
        if not entry.inbox_hidden then
            entry.inbox_hidden = true
            changed = true
        end
    end
    self:_syncUnseen()
    if changed then
        self:_touch({ kind = "cleared", show = true })
    end
    return nil, { cleared = true, created = false, updated = false }
end

-- The entry now on the Audi screen is read. Other entries stay unread.
-- Does not ask for another refresh (kind "shown").
function AudiStore:markDisplayed(id)
    local entry = self:get(id)
    if not entry then
        return false
    end
    local changed = false
    if not entry.read_at then
        entry.read_at = self.now()
        changed = true
    end
    if self.pending_show and self.current_id == entry.id then
        self.pending_show = false
        changed = true
    end
    if not changed then
        return false
    end
    self:_syncUnseen()
    self:_touch({ kind = "shown", show = false, id = entry.id })
    return true
end

-- Marks the current entry read once Audi fullscreen is showing it.
-- With nothing current (the idle line), only a pending flag is cleared.
function AudiStore:markShown()
    local entry = self:current()
    if entry then
        return self:markDisplayed(entry.id)
    end
    if not self.pending_show then
        return false
    end
    self.pending_show = false
    self:_touch({ kind = "shown", show = false })
    return true
end

-- History paging. Not a new delivery, so it doesn't auto-switch or raise the badge.
function AudiStore:setCurrent(id)
    if self.current_id == id then
        return
    end
    self.current_id = id
    self:_touch({ kind = "view", show = false, id = id })
end

function AudiStore:delete(id)
    local entry, index = self:get(id)
    if not entry then
        return false
    end
    self:_removeBody(entry)
    table.remove(self.entries, index)
    if self.current_id == id then
        self.current_id = nil
        self.pending_show = false
    end
    self:_syncUnseen()
    self:_touch({ kind = "deleted", show = false, id = id })
    return true
end

function AudiStore:load()
    local file = io.open(self.path, "r")
    if not file then
        return
    end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" and type(data.entries) == "table" then
        self.entries = data.entries
        self.next_seq = tonumber(data.next_seq) or 1
        self.next_ref = tonumber(data.next_ref) or 1
        self.current_id = type(data.current_id) == "string" and data.current_id or nil
        self.pending_show = data.pending_show == true
        self.unseen = tonumber(data.unseen) or 0
        if self.current_id and not self:get(self.current_id) then
            self.current_id = nil
        end
        -- Files written before read_at existed: treat saved history as already read,
        -- except an entry that arrived and was never shown.
        if data.read_state ~= 1 then
            for _, entry in ipairs(self.entries) do
                local pending = self.pending_show and entry.id == self.current_id
                if not pending and not entry.read_at then
                    entry.read_at = entry.received_at or entry.display_at or 0
                end
            end
            self.dirty = true
        end
        self.read_state = 1
        self:_syncUnseen()
    else
        os.rename(self.path, self.path .. ".bad")
        self.warning = "Saved Audi data was unreadable and has been reset"
    end
end

function AudiStore:flush()
    if not self.dirty then
        return true
    end
    local ok, err = writeFileAtomically(self.path, json.encode({
        entries = self.entries,
        next_seq = self.next_seq,
        next_ref = self.next_ref,
        current_id = self.current_id,
        pending_show = self.pending_show,
        unseen = self.unseen,
        read_state = self.read_state or 1,
    }))
    if not ok then
        return false, err
    end
    self.dirty = false
    return true
end

return AudiStore

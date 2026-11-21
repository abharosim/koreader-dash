-- When to leave Audi mode after the screen has been idle.
-- Pure: no KOReader imports. The dashboard arms a timer; this decides what that timer does.
--
-- Default is 10 minutes. A tap, swipe, key, page turn, or a newly shown Audi entry
-- restarts the window. On resume, the same check uses the time already elapsed.

local Idle = {}

Idle.TIMEOUT_SECONDS = 600

local function timeoutOf(timeout)
    if type(timeout) == "number" and timeout >= 1 then
        return timeout
    end
    return Idle.TIMEOUT_SECONDS
end

function Idle.elapsed(since, now)
    if type(since) ~= "number" or type(now) ~= "number" then
        return nil
    end
    return now - since
end

function Idle.expired(since, now, timeout)
    local elapsed = Idle.elapsed(since, now)
    if not elapsed then
        return false
    end
    return elapsed >= timeoutOf(timeout)
end

-- Seconds left in the window. 0 means the next check should leave.
-- A missing timestamp has the full window left (the caller is about to start it).
function Idle.remaining(since, now, timeout)
    local limit = timeoutOf(timeout)
    local elapsed = Idle.elapsed(since, now)
    if not elapsed then
        return limit
    end
    local left = limit - elapsed
    if left < 1 then
        return 0
    end
    return left
end

-- "leave": Audi has been up long enough with no input; go back to the dash home.
-- "rearm": still inside the window; schedule the remainder.
-- "cancel": not in Audi mode, so the timer must not fire.
function Idle.action(mode, since, now, timeout)
    if mode ~= "audi" then
        return "cancel"
    end
    if Idle.expired(since, now, timeout) then
        return "leave"
    end
    return "rearm"
end

return Idle

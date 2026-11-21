-- Audi body font size, in the same units ScrollHtmlWidget scales from.
-- The previous Audi body size was 20. The default is one step smaller.
-- Pure: no KOReader imports. The view draws it; reader settings store it.

local FontSize = {}

FontSize.MIN = 14
FontSize.MAX = 28
FontSize.STEP = 2
FontSize.DEFAULT = 18

function FontSize.clamp(value)
    local size = tonumber(value)
    if not size or size ~= size or size == math.huge or size == -math.huge then
        return FontSize.DEFAULT
    end
    size = math.floor(size)
    if size < FontSize.MIN then
        return FontSize.MIN
    end
    if size > FontSize.MAX then
        return FontSize.MAX
    end
    return size
end

-- One step, stopped at the ends so a tap past the limit does not wrap.
function FontSize.adjust(value, delta)
    local size = FontSize.clamp(value) + delta
    if size < FontSize.MIN or size > FontSize.MAX then
        return FontSize.clamp(value)
    end
    return size
end

return FontSize

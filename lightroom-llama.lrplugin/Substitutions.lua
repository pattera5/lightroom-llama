-- Keyword substitution list used by LL Optimize Keywords. Edited in the
-- two-column window in SubstitutionEditor.lua; stored in the plug-in
-- preferences as text, one "from -> to" per line (a ";" also separates
-- entries). Plain Lua, no Lightroom APIs, so it can be tested on its own.

local function trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

-- Text to a list of { from, to }. Lines without "->", or with an empty or
-- identical side, are ignored.
local function parse(text)
    local list = {}
    if type(text) ~= "string" then return list end
    for entry in text:gmatch("[^\r\n;]+") do
        local from, to = entry:match("^(.-)%->(.*)$")
        if from then
            from, to = trim(from), trim(to)
            if from ~= "" and to ~= "" and from:lower() ~= to:lower() then
                table.insert(list, { from = from, to = to })
            end
        end
    end
    return list
end

-- List to text, one entry per line
local function format(list)
    local lines = {}
    for _, entry in ipairs(list) do
        table.insert(lines, entry.from .. " -> " .. entry.to)
    end
    return table.concat(lines, "\n")
end

-- The keyword name should be replaced with, following chains (a -> b,
-- b -> c gives c), ignoring capitals. nil if it isn't in the list, or if the
-- chain loops back on itself (a -> b, b -> a).
local function resolve(list, name)
    local map = {}
    for _, entry in ipairs(list) do
        map[entry.from:lower()] = map[entry.from:lower()] or entry.to
    end
    local current, visited = name, { [name:lower()] = true }
    while map[current:lower()] do
        current = map[current:lower()]
        if visited[current:lower()] then
            return nil -- loop
        end
        visited[current:lower()] = true
    end
    if current:lower() == name:lower() then return nil end
    return current
end

-- Adds new { from, to } entries to the text. An existing entry for the same
-- "from" is replaced, and any entry whose "from" is a new "to" is removed
-- (that word is now the one being kept). Returns the new text.
local function add(text, newEntries)
    local list = parse(text)
    for _, new in ipairs(newEntries) do
        local kept = {}
        for _, entry in ipairs(list) do
            local from = entry.from:lower()
            if from ~= new.from:lower() and from ~= new.to:lower() then
                table.insert(kept, entry)
            end
        end
        table.insert(kept, { from = new.from, to = new.to })
        list = kept
    end
    return format(list)
end

return {
    parse = parse,
    format = format,
    resolve = resolve,
    add = add
}

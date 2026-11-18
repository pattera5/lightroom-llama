-- Keyword matching shared by Lightroom Llama (LrLlama.lua) and
-- LL Optimize Keywords (LrOptimizeKeywords.lua). Plain Lua, no Lightroom
-- APIs, so it can be tested with a normal Lua interpreter.
--
-- Load with:
--   local KeywordMatch = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "KeywordMatch.lua"))))()

-- Words that only pad a keyword ("outdoor setting", "forest scene"); ignored
-- when deciding whether two keywords mean the same thing
local fillerWords = {
    setting = true, scene = true, view = true, area = true,
    environment = true, backdrop = true, surroundings = true
}

-- Plurals the simple rules in singularise get wrong
local irregularPlurals = {
    leaves = "leaf", wolves = "wolf", knives = "knife", lives = "life", wives = "wife",
    halves = "half", shelves = "shelf", calves = "calf", loaves = "loaf", thieves = "thief",
    scarves = "scarf", hooves = "hoof", elves = "elf", sheaves = "sheaf",
    people = "person", children = "child", men = "man", women = "woman",
    feet = "foot", teeth = "tooth", geese = "goose", mice = "mouse", oxen = "ox",
    -- words ending in "ie", which the "ies" -> "y" rule would turn into "y"
    movies = "movie", cookies = "cookie", pies = "pie", ties = "tie", brownies = "brownie",
    selfies = "selfie", zombies = "zombie", rookies = "rookie", prairies = "prairie",
    hippies = "hippie", lies = "lie",
    -- words ending in "oes" or "ses" that the rules below get wrong
    tomatoes = "tomato", potatoes = "potato", heroes = "hero", volcanoes = "volcano",
    buses = "bus", lenses = "lens",
    -- words that already look plural; kept as they are so they don't merge
    -- with a different word ("shorts" and "short", "glasses" and "glass")
    shorts = "shorts", news = "news", jeans = "jeans", pants = "pants", clothes = "clothes",
    trousers = "trousers", glasses = "glasses", sunglasses = "sunglasses", goggles = "goggles",
    species = "species", series = "series", lens = "lens", canvas = "canvas",
    christmas = "christmas", atlas = "atlas"
}

-- Crude English singular: "trees" -> "tree", "berries" -> "berry",
-- "boxes" -> "box", "outdoors" -> "outdoor". Leaves "glass", "cactus" alone.
local function singularise(word)
    if irregularPlurals[word] then return irregularPlurals[word] end
    if #word <= 3 then return word end
    if word:match("ss$") or word:match("us$") or word:match("is$") then return word end
    if #word > 4 and word:match("ies$") then return word:sub(1, -4) .. "y" end
    if word:match("sses$") or word:match("xes$") or word:match("ches$") or word:match("shes$") then
        return word:sub(1, -3)
    end
    if word:match("s$") then return word:sub(1, -2) end
    return word
end

-- Simplified form of a keyword used for matching: lower-case, singular, with
-- filler words removed. "Outdoors", "outdoor" and "outdoor setting" all
-- become "outdoor", so they are treated as the same keyword.
local function normaliseKeyword(keyword)
    if type(keyword) ~= "string" then return "" end
    local text = keyword:lower():gsub("[%-_/]", " ")
    local words, kept = {}, {}
    for rawWord in text:gmatch("%S+") do
        local word = singularise(rawWord)
        table.insert(words, word)
        if not fillerWords[word] then
            table.insert(kept, word)
        end
    end
    if #kept == 0 then
        kept = words -- the keyword was only filler words; keep it as is
    end
    return table.concat(kept, " ")
end

return {
    normalise = normaliseKeyword,
    singularise = singularise
}

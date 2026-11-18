-- LL Optimize Keywords
--
-- Finds keywords under 'llm' that mean the same thing (trees/tree,
-- kids/children) and, after you confirm each group, moves their photos to one
-- kept keyword. The other keywords stay in the catalog with no photos and are
-- added as synonyms of the kept one, so searching for them still finds the
-- photos. Keywords outside 'llm' are never changed.
--
-- A run has two stages:
--   1. The substitution list (from -> to, kept in the plug-in preferences and
--      edited with SubstitutionEditor.lua) is applied, after a confirmation.
--   2. Unless "substitution list only" was chosen, new groups are found and
--      shown in a review dialog. Approved merges are added to the list.
--
-- Groups come from four places:
--   * same word: equal after KeywordMatch.normalise (capitals, plurals,
--     filler words such as "scene")
--   * synonym list: the synonymGroups table below
--   * longer forms: another keyword plus one extra word (paddingWords below)
--   * Ollama: the model is given the list of llm keywords and asked for
--     replacement pairs, and each pair is then checked with a separate
--     yes/no question (skipped with a note if Ollama can't be reached)

local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrBinding = import "LrBinding"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"

local logger = LrLogger('LrLlama') -- same log file as Lightroom Llama
logger:enable("logfile")

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- Default Ollama model asked for synonyms (a text-only request); can be
-- changed in the start dialog
local model = "qwen3-vl:4b-instruct"

-- Seconds to wait for Ollama's answer
local requestTimeout = 180

-- Most keywords sent to Ollama (most-used first), to stay inside the model's
-- context size. Keywords past this are still matched by the other methods.
local maxKeywordsForOllama = 1500

-- Largest group Ollama's suggestions may form before it is shown unticked.
-- A bigger group is often the model lumping a topic together (people,
-- actions, feelings) rather than real synonyms, but not always (sportswear,
-- active wear, athletic wear...), so you decide.
local maxOllamaGroupSize = 4

-- Check each pair Ollama suggests with a separate yes/no question before
-- offering it. Much more reliable with small models (the list alone paired
-- "black t-shirt" with "black shorts"); well under a second per pair.
local checkOllamaPairs = true

-- Longer forms: a keyword that is another llm keyword plus one extra word at
-- the start or end ("outdoor event" and "event", "pushing motion" and
-- "pushing") is offered for merging. When the extra word is one of these,
-- the group starts ticked; otherwise it starts unticked for you to check
-- ("smiling woman" and "woman" may be worth keeping apart). Matching
-- ignores capitals and plurals.
local paddingWords = {
    "outdoor", "indoor", "outside", "inside",
    "wooden", "wood", "metal", "metallic", "plastic", "stone", "brick", "concrete",
    "motion", "movement", "action",
}

-- Words that mean the same thing. Each line is one group; any llm keywords
-- matching words in the same group are offered for merging. Matching ignores
-- capitals and plurals, so "kids" matches "kid". Kept to pairs that are safe
-- in photo keywords: "fall" (autumn) and "woods" (forest) are left to Ollama,
-- as they also have other meanings (waterfall, wood as a material).
local synonymGroups = {
    { "child", "kid" },
    { "car", "automobile" },
    { "bicycle", "bike" },
    { "motorcycle", "motorbike" },
    { "aeroplane", "airplane" },
    { "photograph", "photo" },
    { "television", "tv" },
    { "colour", "color" },
    { "grey", "gray" },
    { "sofa", "couch" },
    { "rubbish", "trash", "garbage" },
    { "pavement", "sidewalk" },
    { "mobile phone", "cell phone", "cellphone" },
    { "seagull", "gull" },
    { "path", "pathway" },
    { "outdoor", "outside" },
    { "indoor", "inside" },
    { "night", "nighttime", "night time" },
    { "daytime", "day time" },
}

---------------------------------------------------------------------------

local JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()
local KeywordMatch = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "KeywordMatch.lua"))))()
local normalise = KeywordMatch.normalise
local Substitutions = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "Substitutions.lua"))))()
local SubstitutionEditor = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "SubstitutionEditor.lua"))))(import, _PLUGIN.path)
local prefs = LrPrefs.prefsForPlugin()

local function trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

-- Lower-case names and normalised forms of every keyword outside 'llm'
-- (including their synonyms), used to prefer a spelling you already use
local function getOutsideKeywords(catalog)
    local names, keys = {}, {}
    local function walk(keywords)
        for _, keyword in ipairs(keywords or {}) do
            local name = keyword:getName()
            names[name:lower()] = true
            keys[normalise(name)] = true
            local ok, synonyms = LrTasks.pcall(function() return keyword:getSynonyms() end)
            if ok and type(synonyms) == "table" then
                for _, synonym in ipairs(synonyms) do
                    names[synonym:lower()] = true
                    keys[normalise(synonym)] = true
                end
            end
            walk(keyword:getChildren())
        end
    end
    local topLevel = {}
    for _, keyword in ipairs(catalog:getKeywords() or {}) do
        if keyword:getName() ~= "llm" then
            table.insert(topLevel, keyword)
        end
    end
    walk(topLevel)
    return names, keys
end

-- The keywords directly under 'llm' that are on at least one photo, each as
-- { keyword, name, key, photos, synonyms }, most-used first. Also returns
-- every llm keyword (including unused ones) by lower-case name, and the
-- 'llm' keyword itself. Returns nil if there is no 'llm' keyword or the
-- progress bar was cancelled.
local function getLlmEntries(catalog, progress)
    local llmParent
    for _, keyword in ipairs(catalog:getKeywords() or {}) do
        if keyword:getName() == "llm" then
            llmParent = keyword
            break
        end
    end
    if not llmParent then
        return nil
    end

    local children = llmParent:getChildren() or {}
    local entries, allByLower = {}, {}
    for i, keyword in ipairs(children) do
        if progress:isCanceled() then return nil end
        progress:setPortionComplete(i, #children)
        local ok, photos = LrTasks.pcall(function() return keyword:getPhotos() end)
        local name = keyword:getName()
        local okSyn, synonyms = LrTasks.pcall(function() return keyword:getSynonyms() end)
        local entry = {
            keyword = keyword,
            name = name,
            key = normalise(name),
            photos = (ok and photos) or {},
            synonyms = (okSyn and type(synonyms) == "table") and synonyms or {}
        }
        allByLower[name:lower()] = allByLower[name:lower()] or entry
        if #entry.photos > 0 then
            table.insert(entries, entry)
        end
    end
    table.sort(entries, function(x, y)
        if #x.photos ~= #y.photos then return #x.photos > #y.photos end
        return x.name:lower() < y.name:lower()
    end)
    return entries, allByLower, llmParent
end

-- Reads the llm keywords with a progress bar
local function readLlmKeywords(catalog, caption)
    local progress = LrProgressScope { title = "LL Optimize Keywords: " .. caption }
    local entries, allByLower, llmParent = getLlmEntries(catalog, progress)
    local cancelled = progress:isCanceled()
    progress:done()
    return entries, allByLower, llmParent, cancelled
end

-- Pulls complete {"from": ..., "to": ...} pairs out of reply text, in either
-- order. Used when the reply was cut off or isn't valid JSON, so the pairs
-- written before the problem are still used.
local function salvagePairs(text)
    local found = {}
    for object in text:gmatch("{[^{}]*}") do
        local from = object:match('"from"%s*:%s*"([^"]*)"')
        local to = object:match('"to"%s*:%s*"([^"]*)"')
        if from and to then
            table.insert(found, { from = from, to = to })
        end
    end
    return found
end

-- Sends one request to Ollama, retrying without a setting the model
-- rejects (thinking, JSON mode). Returns Ollama's decoded reply, or nil and a
-- message. logReply writes the raw reply to the log.
local function postToOllama(postData, logReply)
    local url = "http://localhost:11434/api/generate"
    for _ = 1, 3 do
        local response, headers = LrHttp.post(url, JSON:encode(postData),
            {{ field = "Content-Type", value = "application/json" }}, "POST", requestTimeout)
        if not response then
            local errInfo = headers and headers.error or {}
            return nil, "Could not reach Ollama (" .. tostring(errInfo.name or errInfo.errorCode or "no response") .. ")."
        end
        if logReply then
            logger:info("Optimize Keywords: raw API response: " .. response)
        end
        local ok, result = pcall(function() return JSON:decode(response) end)
        if not ok or type(result) ~= "table" then
            return nil, "Ollama returned something that isn't JSON."
        end
        local errText = result.error and tostring(result.error) or nil
        if errText and postData.think ~= nil and errText:lower():find("think", 1, true) then
            postData.think = nil
        elseif errText and postData.format and errText:lower():find("structured output", 1, true) then
            postData.format = nil
        elseif errText then
            return nil, "Ollama error: " .. errText
        else
            return result
        end
    end
    return nil, "Ollama rejected the request."
end

-- Asks Ollama which keywords should be replaced by another keyword in the
-- list. Returns a list of { from, to } pairs (names as the model wrote them)
-- and, if the reply was incomplete, a note; or nil and a message.
local function askOllama(names, modelName)
    local systemPrompt = table.concat({
        "You are given a list of photo keywords, one per line. Find keywords that should be replaced by another keyword in the list because they mean the same thing:",
        "- synonyms (kids -> children, woods -> forest)",
        "- British and American spellings (color -> colour)",
        "- short and long forms of one word (bike -> bicycle)",
        "",
        "Rules:",
        "- Give each replacement as a pair: from (the keyword to replace) and to (the keyword to use instead).",
        "- Both keywords must be in the list. Copy them exactly as written.",
        "- Only pair keywords that someone searching for photos would treat as the same thing.",
        "- Never pair different things, even if they are related or often seen together: different people (woman and girl, man and boy), "
            .. "a kind or part of something (dog and puppy, tree and oak), different objects (phone and camera), "
            .. "different actions (running and jumping), or different feelings (happy and excited).",
        "- Each keyword may be replaced only once. Replace towards the simpler, more common keyword.",
        "- Leave out longer forms that only add a word to another keyword in the list (outdoor event and event); they are found separately.",
        "- Leave out keywords that have no replacement. Most keywords have none, so the list of pairs should be short. If there are none, return an empty list.",
    }, "\n")

    local postData = {
        model = modelName,
        system = systemPrompt,
        prompt = table.concat(names, "\n"),
        format = {
            type = "object",
            properties = {
                pairs = {
                    type = "array",
                    items = {
                        type = "object",
                        properties = { from = { type = "string" }, to = { type = "string" } },
                        required = { "from", "to" }
                    }
                }
            },
            required = { "pairs" }
        },
        stream = false,
        keep_alive = "30m",
        think = false,
        options = {
            temperature = 0,
            num_predict = 3072,
            -- Discourages the model from repeating itself in a loop (as in
            -- Lightroom Llama's own requests)
            repeat_penalty = 1.1,
            num_ctx = 8192
        }
    }

    logger:info("Optimize Keywords: asking " .. modelName .. " about " .. #names .. " keywords")
    logger:info("Optimize Keywords: system prompt: " .. systemPrompt)
    local decoded, err = postToOllama(postData, true)
    if not decoded then
        return nil, err
    end

    local text = decoded.response
    if type(text) ~= "string" then
        return nil, "Ollama gave no answer."
    end
    text = text:gsub("<think>.-</think>", ""):gsub("```%a*", "")
    local firstBrace = text:find("{", 1, true)
    local lastBrace = text:match(".*()}")
    local jsonText = text
    if firstBrace and lastBrace and lastBrace > firstBrace then
        jsonText = text:sub(firstBrace, lastBrace)
    end
    local ok, reply = pcall(function() return JSON:decode(jsonText) end)
    if ok and type(reply) == "table" and type(reply.pairs) == "table" then
        local list = {}
        for _, pair in ipairs(reply.pairs) do
            if type(pair) == "table" and type(pair.from) == "string" and type(pair.to) == "string" then
                table.insert(list, { from = pair.from, to = pair.to })
            end
        end
        return list
    end

    -- Cut off or broken: keep the complete pairs written before the problem
    local list = salvagePairs(text)
    local why = decoded.done_reason == "length" and "was cut off (the model may have got stuck repeating itself)"
        or "wasn't complete JSON"
    logger:warn("Optimize Keywords: reply " .. why .. "; using the " .. #list .. " complete pair(s) in it")
    if #list == 0 then
        return nil, "The model's reply " .. why .. ", and contained no usable pairs."
    end
    return list, "The model's reply " .. why .. "; its first " .. #list .. " suggestion(s) were used."
end

-- Asks Ollama about one pair: do the two keywords mean the same thing?
-- Returns true or false, or nil and a message if there was no clear answer.
local function checkPair(from, to, modelName)
    local postData = {
        model = modelName,
        system = table.concat({
            "You check photo keywords. Answer whether two keywords mean the same thing, so that someone searching for photos would treat them as one keyword.",
            "Answer yes for synonyms (kids and children), spellings (color and colour), short and long forms of one word (bike and bicycle).",
            "Answer no for different things, even if they are related or often seen together: different people (boy and man),",
            "a kind or part of something (tree and hedge), different objects or clothing (black t-shirt and black shorts),",
            "different places or structures (barn and house), different actions (running and jumping), or different feelings (happy and excited).",
        }, "\n"),
        prompt = "Keyword 1: " .. from .. "\nKeyword 2: " .. to .. "\nDo these two keywords mean the same thing?",
        format = {
            type = "object",
            properties = { same = { type = "boolean" } },
            required = { "same" }
        },
        stream = false,
        keep_alive = "30m",
        think = false,
        options = { temperature = 0, num_predict = 20, num_ctx = 8192 }
    }
    local decoded, err = postToOllama(postData, false)
    if not decoded then return nil, err end
    local text = tostring(decoded.response or ""):lower()
    local ok, reply = pcall(function() return JSON:decode(text) end)
    if ok and type(reply) == "table" and type(reply.same) == "boolean" then
        return reply.same
    end
    -- Without JSON mode: look for a plain yes, true, no or false
    if text:find("true", 1, true) or text:match("^%W*yes") then return true end
    if text:find("false", 1, true) or text:match("^%W*no") then return false end
    return nil, "unclear answer: " .. text:sub(1, 60)
end

-- Checks each of Ollama's suggested pairs with a separate question (one pair
-- at a time is far more reliable than the long list). isKnown(name) says
-- whether a name is one of the llm keywords; other pairs are skipped.
-- Returns the pairs kept (a pair that couldn't be checked is kept with
-- unchecked = true) and a note, or nil if cancelled.
local function checkPairs(pairList, modelName, isKnown)
    -- Unique pairs (in either order) of two different known keywords
    local unique, seen = {}, {}
    for _, pair in ipairs(pairList) do
        local a, b = trim(pair.from), trim(pair.to)
        if a:lower() ~= b:lower() and isKnown(a) and isKnown(b) then
            local key = a:lower() < b:lower() and (a:lower() .. "|" .. b:lower()) or (b:lower() .. "|" .. a:lower())
            if not seen[key] then
                seen[key] = true
                table.insert(unique, { from = a, to = b })
            end
        end
    end

    local progress = LrProgressScope { title = "LL Optimize Keywords: checking Ollama's suggestions" }
    local kept, rejected, unchecked = {}, 0, 0
    for i, pair in ipairs(unique) do
        if progress:isCanceled() then
            progress:done()
            return nil
        end
        progress:setPortionComplete(i - 1, #unique)
        progress:setCaption("Checking " .. pair.from .. " / " .. pair.to .. " (" .. i .. " of " .. #unique .. ")")
        local same, err = checkPair(pair.from, pair.to, modelName)
        if same == true then
            table.insert(kept, pair)
        elseif same == false then
            rejected = rejected + 1
            logger:info("Optimize Keywords: check rejected '" .. pair.from .. "' -> '" .. pair.to .. "'")
        else
            unchecked = unchecked + 1
            pair.unchecked = true
            table.insert(kept, pair)
            logger:warn("Optimize Keywords: could not check '" .. pair.from .. "' -> '" .. pair.to .. "': " .. tostring(err))
        end
    end
    progress:done()
    logger:info("Optimize Keywords: checked " .. #unique .. " suggested pair(s): " .. (#kept - unchecked)
        .. " confirmed, " .. rejected .. " rejected, " .. unchecked .. " could not be checked")

    local note = "Ollama suggested " .. #unique .. " pair(s); checking each one rejected " .. rejected .. " of them (listed in the log)."
    if unchecked > 0 then
        note = note .. " " .. unchecked .. " could not be checked and start unticked."
    end
    return kept, note
end

-- Builds the groups to offer. Returns a list of
-- { members = {entry...}, reasons = "same word, Ollama", default = index or 0 }.
-- ollamaPairs is a list of { from, to } names. group.unticked is set when the
-- group should start unticked. Also returns how many of Ollama's groups were
-- larger than maxOllamaGroupSize.
local function findGroups(entries, ollamaPairs, outsideNames, outsideKeys)
    -- Union-find over the entry indexes
    local parent = {}
    for i = 1, #entries do parent[i] = i end
    local function find(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    -- confident = false for links that should leave their group unticked
    -- unless another method also found the same pair
    local links, confidentPairs = {}, {}
    local function pairKey(a, b)
        return math.min(a, b) .. ":" .. math.max(a, b)
    end
    local function link(a, b, reason, confident)
        if a ~= b then
            if confident == nil then confident = true end
            parent[find(a)] = find(b)
            table.insert(links, { a = a, b = b, reason = reason, confident = confident })
            if confident then confidentPairs[pairKey(a, b)] = true end
        end
    end

    -- Same word after normalising
    local firstByKey = {}
    for i, entry in ipairs(entries) do
        if firstByKey[entry.key] then
            link(i, firstByKey[entry.key], "same word")
        else
            firstByKey[entry.key] = i
        end
    end

    -- Synonym list
    local tableGroupOfKey = {}
    for g, words in ipairs(synonymGroups) do
        for _, word in ipairs(words) do
            tableGroupOfKey[normalise(word)] = g
        end
    end
    local firstInTableGroup = {}
    for i, entry in ipairs(entries) do
        local g = tableGroupOfKey[entry.key]
        if g then
            if firstInTableGroup[g] then
                link(i, firstInTableGroup[g], "synonym list")
            else
                firstInTableGroup[g] = i
            end
        end
    end

    -- Longer forms: one extra word at the start or end of another keyword.
    -- If both ways of reading it match ("casual clothing": "clothing" and
    -- "casual"), the one whose extra word is a padding word is used; if that
    -- doesn't decide it, neither is. Collected here, linked after Ollama's
    -- pairs (see below).
    local longerForms = {}
    local paddingSet = {}
    for _, word in ipairs(paddingWords) do paddingSet[normalise(word)] = true end
    for i, entry in ipairs(entries) do
        local words = {}
        for word in entry.key:gmatch("%S+") do table.insert(words, word) end
        if #words >= 2 then
            local options = {}
            local withoutFirst = firstByKey[table.concat(words, " ", 2)]
            local withoutLast = firstByKey[table.concat(words, " ", 1, #words - 1)]
            if withoutFirst then table.insert(options, { base = withoutFirst, padding = paddingSet[words[1]] == true }) end
            if withoutLast then table.insert(options, { base = withoutLast, padding = paddingSet[words[#words]] == true }) end
            local choice
            if #options == 1 then
                choice = options[1]
            elseif #options == 2 and options[1].padding ~= options[2].padding then
                choice = options[1].padding and options[1] or options[2]
            end
            if choice then
                table.insert(longerForms, { i = i, base = choice.base, padding = choice.padding })
            elseif #options == 2 then
                logger:info("Optimize Keywords: '" .. entry.name .. "' could be a longer form of '"
                    .. entries[options[1].base].name .. "' or '" .. entries[options[2].base].name .. "'; not offered")
            end
        end
    end

    -- Ollama's pairs, matched to entries by name (ignoring capitals), or
    -- failing that by normalised form. They are first grouped on their own;
    -- groups bigger than maxOllamaGroupSize start unticked.
    local indexByLower = {}
    for i, entry in ipairs(entries) do
        indexByLower[entry.name:lower()] = indexByLower[entry.name:lower()] or i
    end
    local function indexOf(name)
        if type(name) ~= "string" then return nil end
        return indexByLower[trim(name):lower()] or firstByKey[normalise(name)]
    end
    local ollamaParent = {}
    local function ollamaFind(i)
        ollamaParent[i] = ollamaParent[i] or i
        while ollamaParent[i] ~= i do
            i = ollamaParent[i]
        end
        return i
    end
    local ollamaLinks = {}
    for _, pair in ipairs(ollamaPairs or {}) do
        local a, b = indexOf(pair.from), indexOf(pair.to)
        if a and b and a ~= b then
            ollamaParent[ollamaFind(a)] = ollamaFind(b)
            table.insert(ollamaLinks, { a = a, b = b, unchecked = pair.unchecked })
        end
    end
    local sizes = {}
    for i in pairs(ollamaParent) do
        local root = ollamaFind(i)
        sizes[root] = (sizes[root] or 0) + 1
    end
    local largeRoots = {}
    for _, l in ipairs(ollamaLinks) do
        local root = ollamaFind(l.a)
        if sizes[root] > maxOllamaGroupSize then
            largeRoots[root] = true
            link(l.a, l.b, "Ollama, large group", false)
        elseif l.unchecked then
            link(l.a, l.b, "Ollama, unchecked", false)
        else
            link(l.a, l.b, "Ollama")
        end
    end
    local largeGroups = 0
    for root in pairs(largeRoots) do
        largeGroups = largeGroups + 1
        local names = {}
        for i in pairs(ollamaParent) do
            if ollamaFind(i) == root then table.insert(names, entries[i].name) end
        end
        logger:info("Optimize Keywords: Ollama group of " .. #names .. " keywords (more than "
            .. maxOllamaGroupSize .. "), shown unticked: " .. table.concat(names, ", "))
    end

    -- Link the longer forms. One without a padding word ("athletic
    -- clothing" and "clothing") is only linked when the longer keyword isn't
    -- already in a group, so an uncertain match can't pull a group of
    -- synonyms together with an unrelated keyword.
    local function inGroup(i)
        local root = find(i)
        for j = 1, #entries do
            if j ~= i and find(j) == root then return true end
        end
        return false
    end
    for _, form in ipairs(longerForms) do
        if form.padding then
            link(form.i, form.base, "longer form", true)
        elseif find(form.i) ~= find(form.base) and not inGroup(form.i) then
            link(form.i, form.base, "longer form", false)
        end
    end

    -- Collect the groups
    local byRoot, order = {}, {}
    for i, entry in ipairs(entries) do
        local root = find(i)
        if not byRoot[root] then
            byRoot[root] = { members = {}, reasonSet = {} }
            table.insert(order, root)
        end
        table.insert(byRoot[root].members, entry) -- entries are most-used first
    end
    for _, l in ipairs(links) do
        local group = byRoot[find(l.a)]
        group.reasonSet[l.reason] = true
        -- A pair found only by a less certain method leaves the group unticked
        if not l.confident and not confidentPairs[pairKey(l.a, l.b)] then
            group.unticked = true
        end
    end

    local groups = {}
    for _, root in ipairs(order) do
        local group = byRoot[root]
        if #group.members > 1 then
            local reasons = {}
            for _, reason in ipairs({ "same word", "synonym list", "longer form", "Ollama", "Ollama, unchecked", "Ollama, large group" }) do
                if group.reasonSet[reason] then table.insert(reasons, reason) end
            end
            group.reasons = table.concat(reasons, ", ")

            -- Default keyword to keep, in order of preference: one whose
            -- spelling you already use outside llm; one matching an outside
            -- keyword's normalised form; a shorter form contained in another
            -- member ("obstacle course" in "outdoor obstacle course"); the
            -- most used. A tie is left for you to choose.
            local function outsideScore(entry)
                if outsideNames[entry.name:lower()] then return 2 end
                if outsideKeys[entry.key] then return 1 end
                return 0
            end
            local function isShorterForm(entry)
                local inner = " " .. entry.name:lower() .. " "
                for _, other in ipairs(group.members) do
                    if other ~= entry and (" " .. other.name:lower() .. " "):find(inner, 1, true) then
                        return 1
                    end
                end
                return 0
            end
            local function rank(entry)
                return { outsideScore(entry), isShorterForm(entry), #entry.photos }
            end
            local function compare(x, y) -- 1 if x is preferred, -1 if y, 0 if equal
                for k = 1, 3 do
                    if x[k] ~= y[k] then return x[k] > y[k] and 1 or -1 end
                end
                return 0
            end
            local best, bestRank, tie = 1, rank(group.members[1]), false
            for i = 2, #group.members do
                local r = rank(group.members[i])
                local c = compare(r, bestRank)
                if c > 0 then
                    best, bestRank, tie = i, r, false
                elseif c == 0 then
                    tie = true
                end
            end
            group.default = tie and 0 or best
            group.preferredOutside = bestRank[1] > 0 and not tie
            table.insert(groups, group)
        end
    end
    return groups, largeGroups
end

local function photoCount(n)
    return n == 1 and "1 photo" or (n .. " photos")
end

-- Shows the review dialog. Returns the chosen { group, keep } pairs, or nil
-- if cancelled.
local function reviewDialog(context, groups, note)
    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)
    local rows = {}

    for i, group in ipairs(groups) do
        local names, items = {}, {}
        if group.default == 0 then
            table.insert(items, { title = "Choose one...", value = 0 })
        end
        for j, member in ipairs(group.members) do
            table.insert(names, member.name .. " (" .. #member.photos .. ")")
            table.insert(items, { title = member.name .. " (" .. photoCount(#member.photos) .. ")", value = j })
        end
        props["include" .. i] = not group.unticked
        props["keep" .. i] = group.default

        local notes = { "Found by: " .. group.reasons }
        if group.unticked then
            table.insert(notes, "Not ticked: check before merging")
        end
        if group.default == 0 then
            table.insert(notes, "Same number of photos: please choose which to keep")
        elseif group.preferredOutside then
            table.insert(notes, "Kept spelling also used outside llm")
        end
        local why = table.concat(notes, ". ") .. "."

        table.insert(rows, f:row {
            f:checkbox { value = LrView.bind("include" .. i), title = "", width = 20 },
            f:column {
                f:static_text { title = table.concat(names, ", "), width = 330, height_in_lines = 2 },
                f:static_text { title = why, width = 330, font = "<system/small>" },
            },
            f:static_text { title = "Keep:" },
            f:popup_menu { value = LrView.bind("keep" .. i), items = items, width = 200 },
        })
        table.insert(rows, f:separator { fill_horizontal = 1 })
    end

    local header = {
        f:static_text {
            title = "Found " .. #groups .. " group(s) of llm keywords that look like the same thing. "
                .. "For each ticked group, photos get the kept keyword instead of the others. "
                .. "The others stay in the catalog with no photos and become synonyms of the kept "
                .. "keyword, so searching for them still finds the photos.",
            width = 600, height_in_lines = 3
        }
    }
    if note then
        table.insert(header, f:static_text { title = note, width = 600, height_in_lines = 3 })
    end

    local contents = f:column {
        bind_to_object = props,
        spacing = f:control_spacing(),
        f:column(header),
        f:row {
            f:push_button { title = "Tick all", action = function()
                for i = 1, #groups do props["include" .. i] = true end
            end },
            f:push_button { title = "Untick all", action = function()
                for i = 1, #groups do props["include" .. i] = false end
            end },
        },
        f:scrolled_view {
            width = 640, height = 420, horizontal_scroller = false,
            f:column(rows)
        }
    }

    local result = LrDialogs.presentModalDialog {
        title = "LL Optimize Keywords",
        contents = contents,
        actionVerb = "Merge",
        cancelVerb = "Cancel"
    }
    if result ~= "ok" then
        return nil
    end

    local chosen, unchosen = {}, 0
    for i, group in ipairs(groups) do
        if props["include" .. i] then
            local keep = props["keep" .. i]
            if keep and keep > 0 then
                table.insert(chosen, { group = group, keep = keep })
            else
                unchosen = unchosen + 1
            end
        end
    end
    return chosen, unchosen
end

-- Carries out merges, each { kept = entry, others = { entry... } }: photos
-- get the kept keyword instead of the others, and the others' names (and
-- their synonyms) become synonyms of the kept keyword. Returns keywords
-- merged, photos changed, and the { from, to } pairs done.
local function applyMerges(catalog, merges)
    local keywordsMerged, photosChanged, counted, done = 0, 0, {}, {}
    catalog:withWriteAccessDo("LL Optimize Keywords", function()
        for _, merge in ipairs(merges) do
            local kept = merge.kept
            local synonyms, seen = {}, { [kept.name:lower()] = true }
            local function addSynonym(name)
                if not seen[name:lower()] then
                    seen[name:lower()] = true
                    table.insert(synonyms, name)
                end
            end
            for _, synonym in ipairs(kept.synonyms) do addSynonym(synonym) end

            for _, other in ipairs(merge.others) do
                for _, photo in ipairs(other.photos) do
                    photo:addKeyword(kept.keyword)
                    photo:removeKeyword(other.keyword)
                    local id = photo.localIdentifier
                    if not counted[id] then
                        counted[id] = true
                        photosChanged = photosChanged + 1
                    end
                end
                addSynonym(other.name)
                for _, synonym in ipairs(other.synonyms) do addSynonym(synonym) end
                keywordsMerged = keywordsMerged + 1
                table.insert(done, { from = other.name, to = kept.name })
                logger:info("Optimize Keywords: merged '" .. other.name .. "' (" .. #other.photos
                    .. " photos) into '" .. kept.name .. "'")
            end

            local ok, err = LrTasks.pcall(function()
                kept.keyword:setAttributes { synonyms = synonyms }
            end)
            if not ok then
                logger:warn("Optimize Keywords: could not set synonyms on '" .. kept.name .. "': " .. tostring(err))
            end
        end
    end, { timeout = 60 })
    return keywordsMerged, photosChanged, done
end

-- Applies the substitution list from the Plug-in Manager. Returns a summary
-- line (nil if nothing was done), or false if the user cancelled.
local function runSubstitutions(catalog, listOnly)
    local list = Substitutions.parse(prefs.substitutions)
    if #list == 0 then
        return nil
    end

    local entries, allByLower, llmParent, cancelled = readLlmKeywords(catalog, "reading llm keywords")
    if cancelled then return false end
    if not entries then return nil end

    -- Group the keywords to replace by their replacement
    local byTarget, order = {}, {}
    for _, entry in ipairs(entries) do
        local to = Substitutions.resolve(list, entry.name)
        if to then
            local target = byTarget[to:lower()]
            if not target then
                target = { name = to, others = {} }
                byTarget[to:lower()] = target
                table.insert(order, target)
            end
            table.insert(target.others, entry)
        end
    end
    if #order == 0 then
        return nil
    end

    local lines = {}
    for _, target in ipairs(order) do
        for _, other in ipairs(target.others) do
            table.insert(lines, other.name .. " (" .. photoCount(#other.photos) .. ") -> " .. target.name)
        end
    end
    local shown = {}
    for i = 1, math.min(#lines, 25) do shown[i] = lines[i] end
    if #lines > 25 then
        table.insert(shown, "... and " .. (#lines - 25) .. " more")
    end
    local answer = LrDialogs.confirm("Apply the substitution list?",
        "These llm keywords will be replaced on their photos:\n\n" .. table.concat(shown, "\n"),
        "Apply", "Cancel", (not listOnly) and "Skip" or nil)
    if answer == "cancel" then return false end
    if answer ~= "ok" then return nil end

    -- Create replacement keywords that don't exist yet under 'llm'. A keyword
    -- created in a catalog write can't be used until the write ends, so
    -- this is a separate step.
    local missing = {}
    for _, target in ipairs(order) do
        if not allByLower[target.name:lower()] then
            table.insert(missing, target.name)
        end
    end
    if #missing > 0 then
        catalog:withWriteAccessDo("LL Optimize Keywords: new keywords", function()
            for _, name in ipairs(missing) do
                catalog:createKeyword(name, {}, true, llmParent, true)
            end
        end, { timeout = 30 })
        for _, keyword in ipairs(llmParent:getChildren() or {}) do
            local name = keyword:getName()
            if not allByLower[name:lower()] then
                local ok, synonyms = LrTasks.pcall(function() return keyword:getSynonyms() end)
                allByLower[name:lower()] = {
                    keyword = keyword, name = name, photos = {},
                    synonyms = (ok and type(synonyms) == "table") and synonyms or {}
                }
            end
        end
    end

    local merges = {}
    for _, target in ipairs(order) do
        local kept = allByLower[target.name:lower()]
        if kept then
            table.insert(merges, { kept = kept, others = target.others })
        else
            logger:warn("Optimize Keywords: could not find or create '" .. target.name .. "'")
        end
    end
    local keywordsMerged, photosChanged = applyMerges(catalog, merges)
    return "Substitution list: " .. keywordsMerged .. " keyword(s) replaced, " .. photoCount(photosChanged) .. " updated."
end

-- First dialog: what to run, the model, and a button to edit the
-- substitution list. Returns "full" or "list" and the model name, or nil if
-- cancelled.
local function startDialog(context)
    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)
    props.mode = "full"
    props.model = model -- editable in the dialog; not saved
    local function listText()
        return "The substitution list has " .. SubstitutionEditor.countText() .. ". It is applied first."
    end
    props.listText = listText()
    local result = LrDialogs.presentModalDialog {
        title = "LL Optimize Keywords",
        contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:row {
                f:static_text { title = LrView.bind("listText"), width = 330 },
                f:push_button {
                    title = "Edit substitution list...",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            if SubstitutionEditor.edit() then
                                props.listText = listText()
                            end
                        end)
                    end
                },
            },
            f:radio_button {
                title = "Apply the substitution list, then look for new keywords to merge",
                value = LrView.bind("mode"), checked_value = "full"
            },
            f:radio_button {
                title = "Apply the substitution list only",
                value = LrView.bind("mode"), checked_value = "list"
            },
            f:row {
                f:static_text { title = "Model:" },
                f:edit_field {
                    value = LrView.bind("model"),
                    width_in_chars = 24,
                    tooltip = "Any Ollama model you have installed (see 'ollama list'); used to find synonyms"
                }
            },
        },
        actionVerb = "Start",
        cancelVerb = "Cancel"
    }
    if result ~= "ok" then return nil end
    local modelName = trim(props.model or "")
    if modelName == "" then modelName = model end
    return props.mode, modelName
end

local function main(context)
    local catalog = LrApplication.activeCatalog()

    local mode, modelName = startDialog(context)
    if not mode then return end

    -- 1. Substitution list
    local okSub, subSummary = LrTasks.pcall(runSubstitutions, catalog, mode == "list")
    if not okSub then
        logger:error("Optimize Keywords: substitution list failed: " .. tostring(subSummary))
        LrDialogs.message("LL Optimize Keywords",
            "Could not apply the substitution list. Lightroom may be busy; please try again.\n(" .. tostring(subSummary) .. ")",
            "critical")
        return
    end
    if subSummary == false then return end -- cancelled
    if mode == "list" then
        LrDialogs.message("LL Optimize Keywords",
            subSummary or "Nothing to substitute: no llm keywords on photos match the substitution list.", "info")
        return
    end
    local summaryStart = subSummary and (subSummary .. "\n\n") or ""

    -- 2. Look for new groups
    local entries, _, _, cancelled = readLlmKeywords(catalog, "reading llm keywords")
    if cancelled then return end
    if not entries or #entries < 2 then
        LrDialogs.message("LL Optimize Keywords", summaryStart .. "There are no llm keywords to compare.", "info")
        return
    end
    local outsideNames, outsideKeys = getOutsideKeywords(catalog)

    -- Ask Ollama (most-used keywords first, up to the limit)
    local progress = LrProgressScope { title = "LL Optimize Keywords: asking Ollama for synonyms" }
    context:addCleanupHandler(function() progress:done() end)
    progress:setIndeterminate()
    local names = {}
    for i = 1, math.min(#entries, maxKeywordsForOllama) do
        names[i] = entries[i].name
    end
    local withCounts = {}
    for i, name in ipairs(names) do
        withCounts[i] = name .. " (" .. #entries[i].photos .. ")"
    end
    logger:info("Optimize Keywords: keywords sent to Ollama (photo count, most used first): " .. table.concat(withCounts, ", "))
    local ollamaPairs, ollamaMessage = askOllama(names, modelName)
    local notes = {}
    if not ollamaPairs then
        logger:warn("Optimize Keywords: Ollama not used: " .. tostring(ollamaMessage))
        table.insert(notes, "Ollama was not used, so only same-word, synonym-list and longer-form matches are shown. " .. tostring(ollamaMessage))
    elseif ollamaMessage then
        table.insert(notes, ollamaMessage)
    end
    if ollamaPairs and #entries > maxKeywordsForOllama then
        table.insert(notes, "Ollama was given the " .. maxKeywordsForOllama .. " most-used of " .. #entries .. " llm keywords.")
    end
    progress:done()

    -- Check each suggested pair on its own
    if ollamaPairs and checkOllamaPairs then
        local known = {}
        for _, entry in ipairs(entries) do
            known[entry.name:lower()] = true
            known[entry.key] = true
        end
        local function isKnown(name)
            return known[name:lower()] or known[normalise(name)] or false
        end
        local checkNote
        ollamaPairs, checkNote = checkPairs(ollamaPairs, modelName, isKnown)
        if not ollamaPairs then return end -- cancelled
        table.insert(notes, checkNote)
    end

    local groups, largeGroups = findGroups(entries, ollamaPairs, outsideNames, outsideKeys)
    if largeGroups > 0 then
        table.insert(notes, largeGroups .. " group(s) suggested by Ollama have more than " .. maxOllamaGroupSize
            .. " keywords and start unticked.")
    end
    local note = #notes > 0 and table.concat(notes, " ") or nil
    logger:info("Optimize Keywords: " .. #entries .. " llm keywords in use, " .. #groups .. " groups found")
    if #groups == 0 then
        LrDialogs.message("LL Optimize Keywords",
            summaryStart .. "No llm keywords that mean the same thing were found.\n\n" .. (note or ""), "info")
        return
    end

    local chosen, unchosen = reviewDialog(context, groups, note)
    if not chosen then return end
    if #chosen == 0 then
        LrDialogs.message("LL Optimize Keywords", summaryStart .. "No groups were merged.", "info")
        return
    end

    local merges = {}
    for _, choice in ipairs(chosen) do
        local others = {}
        for j, member in ipairs(choice.group.members) do
            if j ~= choice.keep then table.insert(others, member) end
        end
        table.insert(merges, { kept = choice.group.members[choice.keep], others = others })
    end

    local ok, keywordsMerged, photosChanged, done = LrTasks.pcall(applyMerges, catalog, merges)
    if not ok then
        logger:error("Optimize Keywords: could not save: " .. tostring(keywordsMerged))
        LrDialogs.message("LL Optimize Keywords",
            summaryStart .. "Could not save the changes. Lightroom may be busy; please try again.\n(" .. tostring(keywordsMerged) .. ")",
            "critical")
        return
    end

    -- Remember the merges, so the substitution list applies them next time
    prefs.substitutions = Substitutions.add(prefs.substitutions, done)

    local message = summaryStart .. keywordsMerged .. " keyword(s) merged in " .. #chosen .. " group(s); "
        .. photoCount(photosChanged) .. " updated. The merged keywords are still in the catalog with no photos, "
        .. "and the merges were added to the substitution list."
    if unchosen > 0 then
        message = message .. "\n\n" .. unchosen .. " ticked group(s) were skipped because no keyword to keep was chosen."
    end
    LrDialogs.message("LL Optimize Keywords", message, "info")
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("LLOptimizeKeywords", main)
end)

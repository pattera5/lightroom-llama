local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrApplication = import "LrApplication"
local LrErrors = import "LrErrors"
local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrFileUtils = import 'LrFileUtils'
local LrStringUtils = import 'LrStringUtils'
local LrBinding = import "LrBinding"
local LrColor = import "LrColor"
local LrProgressScope = import "LrProgressScope"
local LrDate = import "LrDate"

local logger = LrLogger('LrLlama')
logger:enable("logfile")
-- Log file location (Lightroom Classic 14 and later):
--   macOS:   ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrLlama.log
--   Windows: %LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\LrLlama.log
-- Watch it live on macOS: tail -f ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrLlama.log
-- (Older Lightroom versions wrote to Documents/LrClassicLogs instead.)

local model = "qwen3-vl:4b-instruct" -- default; can be changed in the dialog

-- Longest side, in pixels, of the image sent to the model. Larger shows the
-- model more detail but takes longer per photo (was 512).
local thumbnailSize = 768

-- Most keywords kept from each reply. The prompt asks for 7 to 15, but small
-- models sometimes return more; anything past this is dropped.
local maxKeywords = 15

-- Whether to list your existing 'llm' keywords in the prompt. Off by default:
-- small models tend to copy unrelated keywords from the list (from other
-- photos). Near-duplicates are still matched to existing keywords in code.
local offerVocabularyToModel = false

-- Seconds to wait for Ollama to answer one photo before giving up. Lightroom's
-- own default is much shorter than a slow photo can take, which caused
-- "The request timed out" errors in larger batches.
local requestTimeout = 180

-- Most tokens a reply may use. A normal reply is about 200; this stops a
-- model that gets stuck repeating itself from running on until the request
-- times out.
local maxReplyTokens = 600

-- Models found not to support Ollama's JSON mode during this Lightroom session
local noJsonModeModels = {}
-- Models that reject the "think" setting (they have no thinking mode)
local noThinkSettingModels = {}

logger:info("Initializing Lightroom Llama Plugin")

JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()

-- Width and height of a JPEG, read from its header (nil if not found)
local function jpegSize(data)
    local i, n = 3, #data
    while i + 8 <= n do
        if data:byte(i) ~= 0xFF then
            i = i + 1
        else
            local marker = data:byte(i + 1)
            if marker == 0xFF then
                i = i + 1
            elseif (marker >= 0xC0 and marker <= 0xCF) and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                local height = data:byte(i + 5) * 256 + data:byte(i + 6)
                local width = data:byte(i + 7) * 256 + data:byte(i + 8)
                return width, height
            elseif marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
                i = i + 2
            else
                local length = data:byte(i + 2) * 256 + data:byte(i + 3)
                i = i + 2 + length
            end
        end
    end
    return nil
end

local function exportThumbnail(photo)
    local tempPath = LrFileUtils.chooseUniqueFileName(
        LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), "llama_thumbnail.jpg"))

    -- requestJpegThumbnail is asynchronous, and Lightroom may call back more
    -- than once: first with a quick low-quality preview, then with a better
    -- one. Keep the largest image received, and stop waiting once one is
    -- (close to) the requested size. Keep a reference to the request so it
    -- isn't garbage-collected (which would cancel it).
    local best, bestSide, failed = nil, 0, false
    local request = photo:requestJpegThumbnail(thumbnailSize, thumbnailSize, function(jpegData, errorMsg)
        if jpegData then
            local w, h = jpegSize(jpegData)
            local side = math.max(w or 0, h or 0)
            if side == 0 then side = 1 end -- size unknown; still usable
            if not best or side > bestSide then
                best, bestSide = jpegData, side
            end
        else
            failed = true
            logger:warn("Thumbnail request failed: " .. tostring(errorMsg))
        end
    end)

    local fullSize = thumbnailSize * 0.9
    local waited, firstAt = 0, nil
    while waited < 15 do
        if best and not firstAt then firstAt = waited end
        if best and bestSide >= fullSize then break end
        -- Give a better version up to 5 seconds after the first one arrives
        if firstAt and waited - firstAt >= 5 then break end
        if failed and not best then break end
        LrTasks.sleep(0.1)
        waited = waited + 0.1
    end
    request = nil -- release the request now that we're finished with it

    if best then
        local tempFile = io.open(tempPath, "wb")
        if tempFile then
            tempFile:write(best)
            tempFile:close()
            logger:info("Thumbnail saved (" .. bestSide .. " px longest side) to " .. tempPath)
            if bestSide < fullSize then
                logger:warn("Only a " .. bestSide .. " px thumbnail was available (wanted " .. thumbnailSize .. ")")
            end
            return tempPath
        end
    end
    logger:warn("Failed to export thumbnail")
    return nil
end

-- Date and place recorded for the photo, as text for the prompt (nil if none)
local function getPhotoFacts(photo)
    local lines = {}

    local time
    for _, field in ipairs({ "dateTimeOriginal", "dateTime" }) do
        local ok, value = LrTasks.pcall(function() return photo:getRawMetadata(field) end)
        if ok and type(value) == "number" then
            time = value
            break
        end
    end
    if time then
        table.insert(lines, "Taken: " .. LrDate.timeToUserFormat(time, "%d %B %Y, %H:%M"))
    end

    local places = {}
    for _, field in ipairs({ "location", "city", "stateProvince", "country" }) do
        local ok, value = LrTasks.pcall(function() return photo:getFormattedMetadata(field) end)
        if ok and type(value) == "string" and value:match("%S") then
            table.insert(places, value)
        end
    end
    if #places > 0 then
        table.insert(lines, "Location: " .. table.concat(places, ", "))
    end

    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

local function base64EncodeImage(imagePath)

    -- Read the image file as binary
    local file = io.open(imagePath, "rb") -- Open the file in binary mode
    if not file then
        LrDialogs.message("Error", "Could not open file: " .. imagePath, "critical")
        return
    end

    local binaryData = file:read("*all") -- Read the entire file as binary data
    file:close() -- Close the file

    -- Encode the binary data to Base64
    local base64Data = LrStringUtils.encodeBase64(binaryData)

    return base64Data
end


-- Replace em dashes with commas: "a long day — and night" -> "a long day, and night"
local function removeEmDashes(text)
    text = text:gsub("%s*\226\128\148%s*", ", ") -- em dash (U+2014)
    text = text:gsub("%s+\226\128\147%s+", ", ") -- spaced en dash (U+2013); "2010–2020" is left alone
    text = text:gsub("%s+%-%-%s+", ", ")       -- " -- " used as a dash
    text = text:gsub(",%s*,", ",")             -- tidy doubled commas
    text = text:gsub(",%s*([%.!%?;])", "%1")   -- no comma before end punctuation
    text = text:gsub("^,%s*", "")              -- no leading comma
    text = text:gsub(",%s*$", "")              -- no trailing comma
    return text
end

-- Build the system and user prompts sent to the model. Shared by the request
-- itself and the "Preview prompt" box, so the preview always matches.
local function buildPrompts(prompt, currentData, useCurrentData, useSystemPrompt)
    currentData = currentData or {}

    -- Build the user prompt, adding existing metadata as context when requested
    local userPrompt = ""
    if useCurrentData then
        userPrompt = userPrompt .. "Title: " .. (currentData.title or "") .. "\nCaption: " .. (currentData.caption or "") .. "\n"
    end
    local contextKeywords = currentData.contextKeywords
    if contextKeywords and not contextKeywords:match("^%s*$") then
        userPrompt = userPrompt .. "Existing keywords (verified facts about this photo, e.g. people, places, events, species): "
            .. contextKeywords .. "\n"
            .. "Treat these keywords as accurate. Use them to name the specific people, places and subjects in the title and caption "
            .. "instead of generic descriptions. Do NOT repeat any of these existing keywords in your keywords list; "
            .. "only return new, additional keywords.\n"
    end
    local photoFacts = currentData.photoFacts
    if photoFacts and not photoFacts:match("^%s*$") then
        userPrompt = userPrompt .. "Photo details from the camera and catalog (accurate):\n" .. photoFacts .. "\n"
            .. "Use the date for the season and time of day, and the location for place names, "
            .. "wherever they fit what you see. Include the place name in the keywords.\n"
    end
    if userPrompt ~= "" then
        userPrompt = userPrompt .. "\n"
    end
    userPrompt = userPrompt .. (prompt or "")

    -- System prompt: short and direct, which small vision models follow best.
    -- No sample answer, as small models tend to copy words from one.
    local systemPrompt
    if useSystemPrompt then
        systemPrompt = [[You write photo metadata. Look at the image and return a JSON object with a "title", a "caption" and a list of "keywords". Write in English.

Title: one sentence or phrase, like a news headline, covering who, what, where and the mood of the scene. Mention angle or perspective if notable. No colons, no keyword lists, no repeated words.

Caption: two to four sentences (about 40 to 80 words) that read as a natural description, not a list.
- Open with the main subject and what is happening, then the setting, then light, weather or time of day, then the mood.
- Use concrete visual details such as colours, textures, light and composition rather than vague praise. Avoid words like "stunning", "beautiful", "breathtaking", "captivating" and "serene".
- Write in the present tense and third person, in plain declarative sentences. Never start with "This image", "This photo", "The photo captures" or "In this picture".
- Add something the title does not say. Do not restate the title or reuse its opening words.
- Work any given names, places or events into the sentences naturally.
- Let the mood come from what is visible, without guessing what people think or feel.
- Use commas and full stops. Do not use em dashes or dashes between clauses.

Keywords: 7 to 15 specific keywords. Cover each of these where it applies:
- main subject and type of photo (for example woman, portrait, landscape, close-up)
- clothing and notable objects (for example coat, sunglasses, kayak)
- setting and place (for example park, lake, forest, street)
- season, weather and light (for example autumn, raining, golden hour)
- action or pose (for example standing, paddling)
- mood or concept (for example relaxed, confident, leisure)

Keyword rules:
- Every person, animal and notable object named in the caption must also appear as a keyword.
- Use single words or short phrases, as singular nouns, in lower case except for names of people and places.
- One keyword per idea. Never give variants of the same idea such as "outdoor", "outdoors" and "outdoor setting"; pick one.
- Do not pad keywords with words like "setting", "scene", "view" or "area".
- No camera details, links or trademarks, and no generic words like "photo" or "image".

Only describe what is visible or given to you as fact. Do not guess names, places or dates.]]
    else
        systemPrompt = [[Return a JSON object with a "title" (string), a "caption" (string) and "keywords" (a list of strings) describing the image. Write in English.]]
    end

    -- Keyword vocabulary (only when offerVocabularyToModel is on) goes in the
    -- system prompt, straight after the fixed instructions.
    local vocabulary = currentData.vocabulary
    if vocabulary and not vocabulary:match("^%s*$") then
        systemPrompt = systemPrompt .. "\n\nKeyword vocabulary already in use: " .. vocabulary .. "\n"
            .. "Use this list for spelling and wording: when a keyword here means the same as one you want to give, "
            .. "use the version from this list. It is not a limit. Always add a keyword for every distinct subject "
            .. "you see, including background details such as animals, people or objects, even when it is not in this list."
    end

    -- Anything that differs from photo to photo goes after the vocabulary
    if useSystemPrompt and useCurrentData then
        systemPrompt = systemPrompt .. "\n\nThe photo already has a title and caption, given in the request. Improve on them but keep their meaning and any names, places and facts they contain."
    end

    return systemPrompt, userPrompt
end

---@param photo LrPhoto The photo to send to the API
---@param prompt string The prompt to send to the API
---@param currentData table (optional) The current title, caption, and keywords of the photo
---@param useCurrentData boolean (optional) Whether to use the current title and caption
---@param useSystemPrompt boolean (optional) Whether to use the system prompt
---@param modelName string (optional) Ollama model to use; defaults to the model set at the top of this file
---@return table response The response from the API
local function sendDataToApi(photo, prompt, currentData, useCurrentData, useSystemPrompt, modelName)
    local useModel = (type(modelName) == "string" and modelName:match("^%s*(.-)%s*$")) or ""
    if useModel == "" then
        useModel = model
    end
    logger:info("Sending data to API using model " .. useModel)
    local thumbPath = exportThumbnail(photo)
    if not thumbPath then
        return nil, "Could not create a thumbnail for this photo."
    end
    local encodedImage = base64EncodeImage(thumbPath)
    LrFileUtils.delete(thumbPath) -- temporary file no longer needed
    if not encodedImage then
        return nil, "Could not read the thumbnail file."
    end
    local url = "http://localhost:11434/api/generate"
    currentData = currentData or {}

    local systemPrompt, userPrompt = buildPrompts(prompt, currentData, useCurrentData, useSystemPrompt)

    -- Exact shape of the reply. Ollama constrains the model to this schema, so
    -- every reply has all three fields with the right types.
    local responseSchema = {
        type = "object",
        properties = {
            title = { type = "string" },
            caption = { type = "string" },
            keywords = { type = "array", items = { type = "string" } }
        },
        required = { "title", "caption", "keywords" }
    }

    -- Define data to be sent (as a Lua table)
    local postData = {
        model = useModel,
        prompt = userPrompt,
        system = systemPrompt,
        format = responseSchema,
        images = {encodedImage},
        stream = false,
        -- Keep the model in memory between requests so later Generates don't
        -- wait for it to reload (Ollama's default is 5 minutes)
        keep_alive = "30m",
        -- Turn off step-by-step "thinking" on models that have it (Gemma 4,
        -- Qwen thinking builds). Thinking is slow, can use up the whole reply
        -- allowance and leave the actual answer empty.
        think = false,
        options = {
            -- Lower temperature gives steadier, more factual metadata
            temperature = 0.3,
            num_predict = maxReplyTokens,
            -- Discourages the model from repeating the same keywords in a loop
            repeat_penalty = 1.1,
            -- Room for the prompt, image and reply together. Kept fixed so
            -- Ollama doesn't reload the model between requests.
            num_ctx = 8192
        }
    }

    -- Log the request without the image data, which would bloat the log
    logger:info("System prompt: " .. systemPrompt)
    logger:info("User prompt: " .. userPrompt)

    -- Some models/runtimes reject Ollama's JSON mode ("structured output is
    -- unavailable"). For those we send the request without it and rely on the
    -- prompt plus the JSON extraction below.
    if noJsonModeModels[useModel] then
        postData.format = nil
    end

    local response_data
    if noThinkSettingModels[useModel] then
        postData.think = nil
    end

    for attempt = 1, 3 do
        logger:info("Sending request to " .. url .. " (model " .. useModel .. ", JSON mode " ..
            (postData.format and "on" or "off") .. ", image " .. #encodedImage .. " bytes base64)")

        -- Convert the Lua table to a JSON string
        local jsonPayload = JSON:encode(postData)

        -- Make a POST request
        local response, headers = LrHttp.post(url, jsonPayload, {{
            field = "Content-Type",
            value = "application/json"
        }}, "POST", requestTimeout)

        if not response then
            local errInfo = headers and headers.error or {}
            local reason = tostring(errInfo.name or errInfo.errorCode or "no response")
            -- A timeout means Ollama is running but slow, which is different
            -- from Ollama not running at all
            if reason:lower():find("timed out", 1, true) or tostring(errInfo.errorCode) == "timedOut" then
                return nil, "Ollama took longer than " .. requestTimeout .. " seconds to answer (request timed out).", "timeout"
            end
            return nil, "Could not reach Ollama at " .. url .. ". Is Ollama running?\n(" .. reason .. ")"
        end

        logger:info("Raw API response: " .. response)

        local okOuter, decoded = pcall(function() return JSON:decode(response) end)
        if not okOuter or type(decoded) ~= "table" then
            return nil, "Ollama returned something that isn't JSON:\n" .. response:sub(1, 300)
        end

        local errText = decoded.error and tostring(decoded.error) or nil
        if errText and postData.think ~= nil and errText:lower():find("think", 1, true) then
            logger:info("Model " .. useModel .. " does not accept the think setting; retrying without it")
            noThinkSettingModels[useModel] = true
            postData.think = nil
        elseif errText and postData.format and errText:lower():find("structured output", 1, true) then
            logger:info("Model " .. useModel .. " does not support JSON mode; retrying without it")
            noJsonModeModels[useModel] = true
            postData.format = nil
        elseif errText then
            -- Ollama reports problems (model not found, out of memory, etc.) as {"error": "..."}
            return nil, "Ollama error: " .. errText
        else
            response_data = decoded
            break
        end
    end

    local text = response_data and response_data.response
    if type(text) ~= "string" or text:match("^%s*$") then
        local doneReason = tostring(response_data and response_data.done_reason or "unknown")
        local thinking = response_data and response_data.thinking
        logger:warn("Empty response (done_reason=" .. doneReason .. ", thinking chars="
            .. tostring(type(thinking) == "string" and #thinking or 0) .. ")")
        if type(thinking) == "string" and thinking ~= "" then
            return nil, "Model '" .. useModel .. "' spent its whole reply thinking and gave no answer. "
                .. "It may not support switching thinking off; try a non-thinking model.", "badjson"
        end
        return nil, "Ollama returned an empty response for model '" .. useModel .. "' (stopped because: " .. doneReason .. ").", "badjson"
    end

    -- Remove any reasoning block and markdown code fences, then take the
    -- outermost {...} so stray text before or after the JSON is ignored
    text = text:gsub("<think>.-</think>", "")
    text = text:gsub("```%a*", "")
    local firstBrace = text:find("{", 1, true)
    local lastBrace
    for i = #text, 1, -1 do
        if text:sub(i, i) == "}" then
            lastBrace = i
            break
        end
    end
    if firstBrace and lastBrace and lastBrace > firstBrace then
        text = text:sub(firstBrace, lastBrace)
    end

    local okInner, response_json = pcall(function() return JSON:decode(text) end)
    if not okInner or type(response_json) ~= "table" then
        local doneReason = tostring(response_data.done_reason or "")
        logger:warn("Invalid JSON from model (done_reason=" .. doneReason .. "): " .. text)
        if doneReason == "length" then
            return nil, "The model's reply was cut off before it finished (it hit the " .. maxReplyTokens
                .. "-token limit, usually because it got stuck repeating itself).", "badjson"
        end
        return nil, "The model's reply wasn't valid JSON. Start of the reply:\n" .. text:sub(1, 300), "badjson"
    end
    -- Remove em dashes (and "--" used as one) from the title and caption,
    -- whatever the prompt said, replacing them with a comma
    for _, field in ipairs({ "title", "caption" }) do
        if type(response_json[field]) == "string" then
            response_json[field] = removeEmDashes(response_json[field])
        end
    end

    -- Split any keyword containing commas ("Oslo, Norway" -> "Oslo", "Norway"),
    -- as Lightroom itself does, so both dialogs save the same keywords
    if type(response_json.keywords) == "table" then
        local split = {}
        for _, keyword in ipairs(response_json.keywords) do
            if type(keyword) == "string" then
                for part in keyword:gmatch("[^,]+") do
                    local trimmed = part:match("^%s*(.-)%s*$")
                    if trimmed ~= "" then
                        table.insert(split, trimmed)
                    end
                end
            end
        end
        response_json.keywords = split
    end

    -- Enforce the keyword maximum, keeping the model's first (most relevant) ones
    if type(response_json.keywords) == "table" and #response_json.keywords > maxKeywords then
        logger:info("Model returned " .. #response_json.keywords .. " keywords; keeping the first " .. maxKeywords)
        local kept = {}
        for i = 1, maxKeywords do
            kept[i] = response_json.keywords[i]
        end
        response_json.keywords = kept
    end

    return response_json
end

-- Words that only pad a keyword ("outdoor setting", "forest scene"); ignored
-- when deciding whether two keywords mean the same thing
local fillerWords = {
    setting = true, scene = true, view = true, area = true,
    environment = true, backdrop = true, surroundings = true
}

-- Crude English singular: "trees" -> "tree", "berries" -> "berry",
-- "boxes" -> "box", "outdoors" -> "outdoor". Leaves "glass", "cactus" alone.
-- Plurals the simple rules below get wrong
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

-- Clean up a list of generated keywords:
--   * drops keywords matching excludeSet (keywords you already have)
--   * merges near-duplicates within the list ("outdoor", "outdoors")
--   * swaps in the existing spelling from vocabulary when one matches, so an
--     existing keyword is reused instead of a new variant being created
local function filterKeywords(keywords, excludeSet, vocabulary)
    local result, seen = {}, {}
    for _, keyword in ipairs(keywords or {}) do
        if type(keyword) == "string" then
            local trimmed = keyword:match("^%s*(.-)%s*$")
            local key = normaliseKeyword(trimmed)
            if key ~= "" and not (excludeSet and excludeSet[key]) then
                local existing = vocabulary and vocabulary.byKey[key]
                if not seen[key] then
                    table.insert(result, existing or trimmed)
                    seen[key] = { index = #result, fromVocabulary = existing ~= nil }
                elseif not seen[key].fromVocabulary and #trimmed < #result[seen[key].index] then
                    -- Two new variants of one idea: keep the shorter, plainer one
                    -- ("forest" rather than "forest scene")
                    result[seen[key].index] = trimmed
                end
            end
        end
    end
    return result
end

-- Adds the keywords under the 'llm' parent; returns the list actually added
local function addKeywordsWithParent(catalog, photo, keywords, excludeSet, vocabulary)
    local added = {}
    if keywords and type(keywords) == "table" then
        -- First create or get the parent 'llm' keyword
        local llmKeyword = catalog:createKeyword("llm", nil, true, nil, true)

        for _, keyword in ipairs(filterKeywords(keywords, excludeSet, vocabulary)) do
            if keyword and keyword ~= "" then
                -- Create child keyword under 'llm' parent (or reuse it if it exists)
                local childKeyword = catalog:createKeyword(keyword, nil, true, llmKeyword, true)
                -- Add the keyword object to the photo
                photo:addKeyword(childKeyword)
                -- The keyword's name as stored in the catalog (an existing
                -- keyword may differ in capitals from the name asked for)
                table.insert(added, childKeyword:getName())
            end
        end
    end
    return added
end

---------------------------------------------------------------------------
-- Keyword vocabulary: the keywords already under 'llm' in the catalog
---------------------------------------------------------------------------

-- Most keywords listed in the prompt (all of them are still used for matching)
local maxVocabularyInPrompt = 200

local function addToVocabulary(vocabulary, name)
    local key = normaliseKeyword(name)
    if key ~= "" and not vocabulary.byKey[key] then
        vocabulary.byKey[key] = name
        table.insert(vocabulary.names, name)
    end
end

-- Reads the children of the 'llm' keyword, most-used first
local function getLlmVocabulary(catalog)
    local vocabulary = { names = {}, byKey = {} }
    local llmParent
    for _, keyword in ipairs(catalog:getKeywords() or {}) do
        if keyword:getName() == "llm" then
            llmParent = keyword
            break
        end
    end
    if not llmParent then
        return vocabulary
    end

    local entries = {}
    for _, keyword in ipairs(llmParent:getChildren() or {}) do
        local ok, photos = LrTasks.pcall(function() return keyword:getPhotos() end)
        table.insert(entries, { name = keyword:getName(), uses = (ok and photos) and #photos or 0 })
    end
    table.sort(entries, function(x, y)
        if x.uses ~= y.uses then return x.uses > y.uses end
        return x.name:lower() < y.name:lower()
    end)
    for _, entry in ipairs(entries) do
        addToVocabulary(vocabulary, entry.name)
    end
    logger:info("Loaded " .. #vocabulary.names .. " existing llm keywords as vocabulary")
    return vocabulary
end

-- Comma-separated list for the prompt (capped at maxVocabularyInPrompt)
local function vocabularyText(vocabulary)
    if not vocabulary or #vocabulary.names == 0 then
        return nil
    end
    local list = {}
    for i = 1, math.min(#vocabulary.names, maxVocabularyInPrompt) do
        list[i] = vocabulary.names[i]
    end
    return table.concat(list, ", ")
end

-- The photo's keywords under the 'llm' parent, as keyword objects
local function getLlmKeywordObjects(photo)
    local llmKeywords = {}
    local allKeywords = photo:getRawMetadata("keywords")

    if allKeywords then
        for _, keyword in ipairs(allKeywords) do
            local parent = keyword:getParent()
            if parent and parent:getName() == "llm" then
                table.insert(llmKeywords, keyword)
            end
        end
    end

    return llmKeywords
end

local function getLlmKeywordsFromPhoto(photo)
    local names = {}
    for _, keyword in ipairs(getLlmKeywordObjects(photo)) do
        table.insert(names, keyword:getName())
    end
    return names
end

-- Keywords you assigned yourself (everything not under the 'llm' parent)
local function getUserKeywordsFromPhoto(photo)
    local userKeywords = {}
    local allKeywords = photo:getRawMetadata("keywords")

    if allKeywords then
        for _, keyword in ipairs(allKeywords) do
            local parent = keyword:getParent()
            local isLlm = (parent and parent:getName() == "llm") or keyword:getName() == "llm"
            if not isLlm then
                table.insert(userKeywords, keyword:getName())
            end
        end
    end

    return userKeywords
end

-- Set of your own keywords (and their synonyms) on the photo, normalised for matching
local function getUserKeywordSet(photo)
    local set = {}
    local allKeywords = photo:getRawMetadata("keywords")

    if allKeywords then
        for _, keyword in ipairs(allKeywords) do
            local parent = keyword:getParent()
            local isLlm = (parent and parent:getName() == "llm") or keyword:getName() == "llm"
            if not isLlm then
                set[normaliseKeyword(keyword:getName())] = true
                local ok, synonyms = pcall(function() return keyword:getSynonyms() end)
                if ok and type(synonyms) == "table" then
                    for _, synonym in ipairs(synonyms) do
                        set[normaliseKeyword(synonym)] = true
                    end
                end
            end
        end
    end

    return set
end

-- Split a comma-separated string into a list of trimmed, non-empty keywords
local function splitKeywords(str)
    local list = {}
    for keyword in string.gmatch(str or "", "([^,]+)") do
        local trimmed = keyword:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(list, trimmed)
        end
    end
    return list
end

-- Errors that will hit every photo, so there's no point continuing the batch
local function isFatalError(err)
    err = err or ""
    return err:find("Could not reach Ollama", 1, true) or err:find("not found", 1, true)
end

---------------------------------------------------------------------------
-- Batch mode: used when more than one photo is selected
---------------------------------------------------------------------------
local function runBatch(catalog, photos)
    local options

    LrFunctionContext.callWithContext("showLlamaBatchDialog", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.prompt = "Caption this photo"
        props.useCurrentData = true
        props.useContextKeywords = true
        props.useSystemPrompt = true
        props.model = model -- editable in the dialog; not saved
        props.batchKeywords = ""
        props.applyBatchKeywords = true
        props.usePhotoFacts = true
        props.skipCaptioned = false

        local f = LrView.osFactory()
        local c = f:column{
            bind_to_object = props,
            width = 420,
            f:static_text{
                title = #photos .. " photos selected. Each photo is captioned separately using its own title, caption and keywords.",
                width = 420,
                height_in_lines = 2
            },
            f:spacer{ height = 10 },
            f:static_text{ title = "Prompt:" },
            f:spacer{ f:label_spacing{} },
            f:edit_field{
                value = LrView.bind("prompt"),
                width = 420,
                height = 60
            },
            f:spacer{ height = 10 },
            f:checkbox{
                title = "Use each photo's current title and caption",
                value = LrView.bind("useCurrentData")
            },
            f:spacer{ height = 6 },
            f:checkbox{
                title = "Use each photo's existing keywords as context",
                value = LrView.bind("useContextKeywords")
            },
            f:spacer{ height = 6 },
            f:checkbox{
                title = "Use each photo's date and location",
                value = LrView.bind("usePhotoFacts")
            },
            f:spacer{ height = 6 },
            f:checkbox{
                title = "Skip photos that already have a caption",
                value = LrView.bind("skipCaptioned")
            },
            f:spacer{ height = 6 },
            f:checkbox{
                title = "Use system prompt",
                value = LrView.bind("useSystemPrompt")
            },
            f:spacer{ height = 10 },
            f:separator{ width = 420 },
            f:spacer{ height = 10 },
            f:static_text{ title = "Keywords for this batch (comma-separated, optional):" },
            f:spacer{ f:label_spacing{} },
            f:edit_field{
                value = LrView.bind("batchKeywords"),
                width = 420,
                height = 40
            },
            f:spacer{ height = 6 },
            f:static_text{
                title = "These are given to the model as context for every photo.",
                width = 420
            },
            f:spacer{ height = 6 },
            f:checkbox{
                title = "Also add these keywords to every photo",
                value = LrView.bind("applyBatchKeywords")
            },
            f:spacer{ height = 10 },
            f:row{
                f:static_text{ title = "Model:" },
                f:edit_field{
                    value = LrView.bind("model"),
                    width_in_chars = 24,
                    tooltip = "Any Ollama vision model you have installed (see 'ollama list')"
                }
            },
            f:spacer{ height = 6 },
            f:static_text{
                title = "Generated titles and captions replace the existing ones. Choose Edit > Undo after the run to revert a photo.",
                width = 420,
                height_in_lines = 2
            }
        }

        local result = LrDialogs.presentModalDialog({
            title = "Lightroom Llama – Batch",
            contents = c,
            actionVerb = "Generate for " .. #photos .. " photos"
        })

        if result == "ok" then
            options = {
                prompt = props.prompt,
                useCurrentData = props.useCurrentData,
                useContextKeywords = props.useContextKeywords,
                useSystemPrompt = props.useSystemPrompt,
                batchKeywords = splitKeywords(props.batchKeywords),
                applyBatchKeywords = props.applyBatchKeywords,
                usePhotoFacts = props.usePhotoFacts,
                skipCaptioned = props.skipCaptioned,
                model = props.model
            }
        end
    end)

    if not options then
        return
    end

    -- Existing llm keywords, reused across the batch. Keywords added for one
    -- photo are added to it, so similar photos share the same keywords.
    local vocabulary = getLlmVocabulary(catalog)
    -- The list given to the model (only when offerVocabularyToModel is on) is
    -- frozen for the whole batch. Keywords created during the batch are still
    -- matched in code via 'vocabulary'.
    local frozenVocabularyText = offerVocabularyToModel and vocabularyText(vocabulary) or nil

    local progress = LrProgressScope({ title = "Lightroom Llama: captioning " .. #photos .. " photos" })
    local succeeded, failures = 0, {}
    local consecutiveTimeouts = 0
    local skipped = 0
    local stoppedEarly

    -- Captions one photo. Returns a message when the whole batch should stop,
    -- otherwise nil.
    local function processPhoto(i, photo, fileName)
        if options.skipCaptioned and (photo:getFormattedMetadata("caption") or ""):match("%S") then
            skipped = skipped + 1
            logger:info(fileName .. ": skipped (already has a caption)")
            return nil
        end

        -- Gather this photo's own metadata
        local title = photo:getFormattedMetadata("title") or ""
        local caption = photo:getFormattedMetadata("caption") or ""
        local contextList = {}
        if options.useContextKeywords then
            contextList = getUserKeywordsFromPhoto(photo)
        end
        for _, keyword in ipairs(options.batchKeywords) do
            table.insert(contextList, keyword)
        end
        contextList = filterKeywords(contextList, nil)

        -- Keywords the photo has (or will have) that must not be repeated under 'llm'
        local excludeSet = getUserKeywordSet(photo)
        if options.applyBatchKeywords then
            for _, keyword in ipairs(options.batchKeywords) do
                excludeSet[normaliseKeyword(keyword)] = true
            end
        end

        local useCurrent = options.useCurrentData and (title ~= "" or caption ~= "")
        local requestData = {
            title = title,
            caption = caption,
            contextKeywords = (#contextList > 0) and table.concat(contextList, ", ") or nil,
            vocabulary = frozenVocabularyText,
            photoFacts = options.usePhotoFacts and getPhotoFacts(photo) or nil
        }
        local apiResponse, err, errKind = sendDataToApi(photo, options.prompt, requestData,
            useCurrent, options.useSystemPrompt, options.model)

        -- A timed-out photo gets one more try before being counted as failed
        if not apiResponse and (errKind == "timeout" or errKind == "badjson") and not progress:isCanceled() then
            logger:warn(fileName .. ": " .. errKind .. ", retrying once")
            progress:setCaption("Photo " .. i .. " of " .. #photos .. ": " .. fileName .. " (retrying)")
            apiResponse, err, errKind = sendDataToApi(photo, options.prompt, requestData,
                useCurrent, options.useSystemPrompt, options.model)
        end

        if errKind == "timeout" then
            consecutiveTimeouts = consecutiveTimeouts + 1
        else
            consecutiveTimeouts = 0
        end

        if apiResponse then
            local okWrite, writeErr = LrTasks.pcall(function()
                catalog:withWriteAccessDo("Llama metadata: " .. fileName, function()
                    if apiResponse.title and apiResponse.title ~= "" then
                        photo:setRawMetadata("title", apiResponse.title)
                    end
                    if apiResponse.caption and apiResponse.caption ~= "" then
                        photo:setRawMetadata("caption", apiResponse.caption)
                    end
                    if type(apiResponse.keywords) == "table" then
                        local added = addKeywordsWithParent(catalog, photo, apiResponse.keywords, excludeSet, vocabulary)
                        for _, name in ipairs(added) do
                            addToVocabulary(vocabulary, name)
                        end
                    end
                    if options.applyBatchKeywords then
                        for _, keyword in ipairs(options.batchKeywords) do
                            photo:addKeyword(catalog:createKeyword(keyword, {}, true, nil, true))
                        end
                    end
                end, { timeout = 30 })
            end)
            if okWrite then
                succeeded = succeeded + 1
            else
                table.insert(failures, fileName .. ": could not save (" .. tostring(writeErr) .. ")")
            end
        else
            logger:error(fileName .. ": " .. tostring(err))
            table.insert(failures, fileName .. ": " .. tostring(err))
            if isFatalError(err) then
                return "Stopped early: " .. tostring(err)
            end
            if consecutiveTimeouts >= 3 then
                return "Stopped early: Ollama timed out on 3 photos in a row. It may be stuck or short of memory; try restarting it."
            end
        end
        return nil
    end

    for i, photo in ipairs(photos) do
        if progress:isCanceled() then
            stoppedEarly = "Cancelled."
            break
        end
        progress:setPortionComplete(i - 1, #photos)

        local fileName = "photo " .. i
        local okName, name = LrTasks.pcall(function() return photo:getFormattedMetadata("fileName") end)
        if okName and type(name) == "string" and name ~= "" then
            fileName = name
        end
        progress:setCaption("Photo " .. i .. " of " .. #photos .. ": " .. fileName)

        -- An unexpected error on one photo is recorded as a failure and the
        -- batch moves on to the next photo, instead of stopping with
        -- Lightroom's raw error and leaving the progress bar on screen
        local ok, stopReason = LrTasks.pcall(function()
            return processPhoto(i, photo, fileName)
        end)
        if not ok then
            logger:error(fileName .. ": unexpected error: " .. tostring(stopReason))
            table.insert(failures, fileName .. ": unexpected error (" .. tostring(stopReason) .. ")")
        elseif stopReason then
            stoppedEarly = stopReason
            break
        end
    end

    progress:done()

    local summary = succeeded .. " of " .. #photos .. " photos updated."
    if skipped > 0 then
        summary = summary .. " " .. skipped .. " skipped because they already had a caption."
    end
    if stoppedEarly then
        summary = summary .. "\n\n" .. stoppedEarly
    end
    if #failures > 0 then
        local shown = {}
        for i = 1, math.min(#failures, 10) do
            table.insert(shown, failures[i])
        end
        summary = summary .. "\n\nProblems:\n" .. table.concat(shown, "\n")
        if #failures > 10 then
            summary = summary .. "\n…and " .. (#failures - 10) .. " more (see LrLlama.log)."
        end
    end
    LrDialogs.message("Lightroom Llama – Batch finished", summary, (#failures > 0) and "warning" or "info")
end

local function main()
    -- Get the active catalog
    local catalog = LrApplication.activeCatalog()

    -- Get the selected photo
    local selectedPhotos = catalog:getTargetPhotos() -- Gets all selected photos
    if #selectedPhotos == 0 then
        LrDialogs.message("No photo selected", "Please select a photo to view.", "critical")
        return
    end

    -- More than one photo selected: run in batch mode
    if #selectedPhotos > 1 then
        runBatch(catalog, selectedPhotos)
        return
    end

    local selectedPhoto = selectedPhotos[1]
    local thumbnailPath = exportThumbnail(selectedPhoto)
    local photoFacts = getPhotoFacts(selectedPhoto)

    LrFunctionContext.callWithContext("showLlamaDialog", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.status = "Ready"
        props.statusColor = LrColor(0.149, 0.616, 0.412)
        props.prompt = "Caption this photo"
        props.title = selectedPhoto:getFormattedMetadata('title')
        props.caption = selectedPhoto:getFormattedMetadata('caption')
        -- Initialize keywords with existing llm keywords
        local existingLlmKeywords = getLlmKeywordsFromPhoto(selectedPhoto)
        props.keywords = table.concat(existingLlmKeywords, ", ")
        -- Your own keywords, passed to the model as context (editable in the dialog)
        props.contextKeywords = table.concat(getUserKeywordsFromPhoto(selectedPhoto), ", ")
        -- Keywords already on the photo; these are never repeated under 'llm'
        local userKeywordSet = getUserKeywordSet(selectedPhoto)
        -- Existing llm keywords in the catalog, offered to the model for reuse
        local vocabulary = getLlmVocabulary(catalog)
        local frozenVocabularyText = offerVocabularyToModel and vocabularyText(vocabulary) or nil
        props.useContextKeywords = props.contextKeywords ~= ""
        props.response = ""
        props.useCurrentData = props.title ~= "" or props.caption ~= ""
        props.usePhotoFacts = photoFacts ~= nil
        props.useSystemPrompt = true
        props.model = model -- editable in the dialog; not saved
        props.elapsed = "" -- generation time, shown after each run
        props.canGenerate = true -- false while a request is running

        -- "Preview prompt": read-only view of exactly what will be sent
        props.showPromptPreview = false
        props.promptPreview = ""
        local function updatePromptPreview()
            if not props.showPromptPreview then
                return
            end
            local systemPrompt, userPrompt = buildPrompts(props.prompt, {
                title = props.title,
                caption = props.caption,
                contextKeywords = props.useContextKeywords and props.contextKeywords or nil,
                vocabulary = frozenVocabularyText,
                photoFacts = props.usePhotoFacts and photoFacts or nil
            }, props.useCurrentData, props.useSystemPrompt)
            props.promptPreview = "SYSTEM PROMPT" .. (props.useSystemPrompt and "" or " (minimal, \"Use system prompt\" is off)") .. ":\n"
                .. systemPrompt
                .. "\n\nUSER PROMPT:\n" .. userPrompt
                .. "\n\nALSO SENT: the photo (" .. thumbnailSize .. " px), and the required reply format (title, caption, keywords)."
        end
        for _, key in ipairs({ "showPromptPreview", "prompt", "useSystemPrompt", "useCurrentData",
                               "title", "caption", "useContextKeywords", "contextKeywords", "usePhotoFacts" }) do
            props:addObserver(key, updatePromptPreview)
        end

        -- Create a view factory
        local f = LrView.osFactory()

        -- Define the dialog contents
        local c = f:view{
            bind_to_object = props,
            f:row{f:column{
                f:picture{
                    value = thumbnailPath,
                    frame_width = 2,
                    width = 400,
                    height = 400
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Preview prompt",
                    value = LrView.bind("showPromptPreview")
                },
                f:spacer{
                    height = 6
                },
                f:scrolled_view{
                    visible = LrView.bind("showPromptPreview"),
                    width = 400,
                    height = 300,
                    horizontal_scroller = false,
                    f:static_text{
                        title = LrView.bind("promptPreview"),
                        width = 370,
                        height_in_lines = 60,
                        selectable = true
                    }
                },
                width = 400
            }, f:spacer{
                width = 10
            }, f:column{
                f:column{f:static_text{
                    title = "Title:"
                }, f:spacer{f:label_spacing{}}, f:edit_field{
                    value = LrView.bind("title"), -- Bind to the new response property
                    width = 400
                }},
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Caption:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("caption"), -- Bind to the new response property
                    width = 400,
                    height = 100
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Keywords:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("keywords"),
                    width = 400,
                    height = 60
                },
                f:spacer{
                    height = 10
                },
                f:separator{
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Prompt:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("prompt"),
                    immediate = true, -- keep the prompt preview in step while typing
                    width = 400,
                    height = 60
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use current title and caption",
                    value = LrView.bind("useCurrentData")
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use existing keywords as context:",
                    value = LrView.bind("useContextKeywords")
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("contextKeywords"),
                    enabled = LrView.bind("useContextKeywords"),
                    width = 400,
                    height = 40
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use date and location" .. (photoFacts and (": " .. photoFacts:gsub("\n", "; ")) or " (none recorded)"),
                    value = LrView.bind("usePhotoFacts"),
                    enabled = photoFacts ~= nil,
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use system prompt",
                    value = LrView.bind("useSystemPrompt")
                },
                f:spacer{
                    height = 10
                },
                f:separator{
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:row{f:static_text{
                    title = "Model:"
                }, f:edit_field{
                    value = LrView.bind("model"),
                    width_in_chars = 16,
                    tooltip = "Any Ollama vision model you have installed (see 'ollama list')"
                }, f:static_text{
                    title = LrView.bind("elapsed"),
                    width_in_chars = 6,
                    text_color = LrColor(0.0, 0.35, 0.85),
                    tooltip = "Time taken by the last generation"
                }, f:static_text{
                    alignment = 'right',
                    title = LrView.bind("status"),
                    width = 160,
                    font = "<system/bold>",
                    text_color = LrView.bind("statusColor")
                }},
                f:spacer{
                    height = 10
                },
                f:row{f:push_button{
                    title = "Generate",
                    enabled = LrView.bind("canGenerate"), -- off while a request is running
                    action = function()
                        props.canGenerate = false
                        props.status = "The llama is thinking..."
                        props.statusColor = LrColor(0.439, 0.345, 0.745)
                        props.elapsed = ""

                        local function showError(message)
                            props.elapsed = ""
                            logger:error(message)
                            props.status = "Error"
                            props.statusColor = LrColor(0.8, 0.2, 0.2)
                            LrDialogs.message("Lightroom Llama", message or "Unknown error", "critical")
                        end

                        local function generate()
                            local startTime = LrDate.currentTime()
                            local apiResponse, err, errKind
                            for attempt = 1, 2 do
                                apiResponse, err, errKind = sendDataToApi(selectedPhoto, props.prompt, {
                                    title = props.title,
                                    caption = props.caption,
                                    contextKeywords = props.useContextKeywords and props.contextKeywords or nil,
                                    vocabulary = frozenVocabularyText,
                                    photoFacts = props.usePhotoFacts and photoFacts or nil
                                }, props.useCurrentData, props.useSystemPrompt, props.model)
                                -- One automatic retry when the reply comes back broken
                                if apiResponse or errKind ~= "badjson" then
                                    break
                                end
                                logger:warn("Invalid JSON reply, retrying once")
                                props.status = "Retrying..."
                            end

                            if not apiResponse then
                                showError(err)
                                return
                            end

                            -- A blank title or caption never replaces the current one
                            if type(apiResponse.title) == "string" and apiResponse.title:match("%S") then
                                props.title = apiResponse.title
                            end
                            if type(apiResponse.caption) == "string" and apiResponse.caption:match("%S") then
                                props.caption = apiResponse.caption
                            end
                            -- Convert keywords array to comma-separated string for display
                            if apiResponse.keywords and type(apiResponse.keywords) == "table" then
                                props.keywords = table.concat(filterKeywords(apiResponse.keywords, userKeywordSet, vocabulary), ", ")
                            else
                                props.keywords = ""
                            end
                            props.elapsed = string.format("%d s", math.floor(LrDate.currentTime() - startTime + 0.5))
                            props.status = "Ready"
                            props.statusColor = LrColor(0.149, 0.616, 0.412)
                        end

                        LrTasks.startAsyncTask(function()
                            local ok, problem = LrTasks.pcall(generate)
                            if not ok then
                                showError("Something went wrong: " .. tostring(problem))
                            end
                            -- Always turn the button back on, even after an error
                            props.canGenerate = true
                        end)
                    end
                }},
                f:spacer{
                    height = 20
                },
                width = 400
            }}
        }

        -- Show the dialog
        local result = LrDialogs.presentModalDialog({
            title = "Lightroom Llama",
            contents = c,
            actionVerb = "Save",
            -- Save is greyed out while Generate is running, so it can't save
            -- the old text while a new reply is on its way
            actionBinding = {
                enabled = {
                    bind_to_object = props,
                    key = "canGenerate"
                }
            }
        })


        -- The preview thumbnail is no longer needed
        if thumbnailPath then
            LrFileUtils.delete(thumbnailPath)
        end

        if result == "ok" then
            -- The photo's current 'llm' keywords, read before saving so any
            -- no longer in the Keywords box can be removed from the photo
            local oldLlmKeywords = getLlmKeywordObjects(selectedPhoto)
            local removedCount = 0

            -- Save the metadata to the photo
            local okWrite, writeErr = LrTasks.pcall(function()
                catalog:withWriteAccessDo("Save Llama metadata", function()
                    selectedPhoto:setRawMetadata("title", props.title or "")
                    selectedPhoto:setRawMetadata("caption", props.caption or "")
                    -- Add the keywords in the box under the llm parent
                    local added = addKeywordsWithParent(catalog, selectedPhoto,
                        splitKeywords(props.keywords), userKeywordSet, vocabulary)
                    -- Remove llm keywords that are no longer in the box, so the
                    -- photo ends up with exactly the keywords shown. Matching
                    -- is by exact name, so duplicate variants already on the
                    -- photo ("tree" and "trees") are cut down to the one kept.
                    -- Removed keywords stay in the catalog (Metadata > Purge
                    -- Unused Keywords clears them).
                    local keep = {}
                    for _, name in ipairs(added) do
                        keep[name] = true
                    end
                    for _, keyword in ipairs(oldLlmKeywords) do
                        if not keep[keyword:getName()] then
                            selectedPhoto:removeKeyword(keyword)
                            removedCount = removedCount + 1
                        end
                    end
                end, { timeout = 30 })
            end)

            if okWrite then
                local message = "Title, caption, and keywords have been saved to the photo."
                if removedCount > 0 then
                    message = message .. " " .. removedCount .. " llm keyword(s) no longer in the Keywords box were removed from it."
                end
                LrDialogs.message("Metadata Saved", message, "info")
            else
                logger:error("Could not save metadata: " .. tostring(writeErr))
                LrDialogs.message("Lightroom Llama",
                    "Could not save to the photo. Lightroom may be busy; please try again.\n(" .. tostring(writeErr) .. ")",
                    "critical")
            end
        end
    end)
end

LrTasks.startAsyncTask(main)

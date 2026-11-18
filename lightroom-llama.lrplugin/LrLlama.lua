local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrApplication = import "LrApplication"
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

-- Keyword matching function, defined further down with the other keyword
-- helpers but used earlier (in sendDataToApi)
local normaliseKeyword

-- Models found not to support Ollama's JSON mode during this Lightroom session
local noJsonModeModels = {}
-- Models that reject the "think" setting (they have no thinking mode)
local noThinkSettingModels = {}

logger:info("Initializing Lightroom Llama Plugin")

local JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()

-- Status colours in the single-photo dialog
local colourReady = LrColor(0.149, 0.616, 0.412)
local colourBusy = LrColor(0.439, 0.345, 0.745)
local colourError = LrColor(0.8, 0.2, 0.2)

-- Text with spaces removed from both ends
local function trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

-- Split a comma-separated string into a list of trimmed, non-empty keywords
local function splitKeywords(str)
    local list = {}
    for part in (str or ""):gmatch("[^,]+") do
        local trimmed = trim(part)
        if trimmed ~= "" then
            table.insert(list, trimmed)
        end
    end
    return list
end

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

-- Date and place recorded for the photo, as text for the prompt (nil if
-- none), plus the list of place names (used to keep them out of keywords).
-- raw and formatted are optional: the photo's metadata already read in bulk
-- (batch mode); without them each field is read from the photo.
local function getPhotoFacts(photo, raw, formatted)
    local function readRaw(field)
        if raw then return raw[field] end
        local ok, value = LrTasks.pcall(function() return photo:getRawMetadata(field) end)
        return ok and value or nil
    end
    local function readFormatted(field)
        if formatted then return formatted[field] end
        local ok, value = LrTasks.pcall(function() return photo:getFormattedMetadata(field) end)
        return ok and value or nil
    end

    local lines = {}

    local time
    for _, field in ipairs({ "dateTimeOriginal", "dateTime" }) do
        local value = readRaw(field)
        if type(value) == "number" then
            time = value
            break
        end
    end
    if time then
        table.insert(lines, "Taken: " .. LrDate.timeToUserFormat(time, "%d %B %Y, %H:%M"))
    end

    local places = {}
    for _, field in ipairs({ "location", "city", "stateProvince", "country" }) do
        local value = readFormatted(field)
        if type(value) == "string" and value:match("%S") then
            table.insert(places, value)
        end
    end
    if #places > 0 then
        table.insert(lines, "Location: " .. table.concat(places, ", "))
    end

    if #lines == 0 then
        return nil, places
    end
    return table.concat(lines, "\n"), places
end

-- The image file as Base64 text (nil if it can't be read; the caller reports it)
local function base64EncodeImage(imagePath)
    local file = io.open(imagePath, "rb")
    if not file then
        logger:warn("Could not open thumbnail file: " .. imagePath)
        return nil
    end
    local binaryData = file:read("*all")
    file:close()
    return LrStringUtils.encodeBase64(binaryData)
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
local function buildPrompts(prompt, currentData, useCurrentData)
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
            .. "only return new, additional keywords. They are already saved and do not count towards the 7 to 15 keywords. "
            .. "Still give the general word for each person named here (for example woman, man, child).\n"
    end
    local photoFacts = currentData.photoFacts
    if photoFacts and not photoFacts:match("^%s*$") then
        userPrompt = userPrompt .. "Photo details from the camera and catalog (accurate):\n" .. photoFacts .. "\n"
            .. "These are background information. Use the date for the season and time of day, and the location "
            .. "for place names in the title and caption, wherever they fit what you see. "
            .. "Do not use these place names as keywords, but do give the type of place (for example park, lake, beach). "
            .. "The place names do not count towards the 7 to 15 keywords.\n"
    end
    -- Anything typed in the "Additional prompt text" box goes last
    local extra = trim(prompt or "")
    if extra ~= "" then
        if userPrompt ~= "" then
            userPrompt = userPrompt .. "\n"
        end
        userPrompt = userPrompt .. extra
    end
    -- Ollama treats an empty prompt as "load the model only" and gives no
    -- answer, so a request with nothing else to say still needs a line
    if userPrompt == "" then
        userPrompt = "Caption this photo."
    end

    -- System prompt: short and direct, which small vision models follow best.
    -- No sample answer, as small models tend to copy words from one.
    local systemPrompt = [[You write photo metadata. Caption the photo you are given: look at the image and return a JSON object with a "title", a "caption" and a list of "keywords". Write in English.

Title: one sentence or phrase, like a news headline, covering who, what, where and the mood of the scene. Mention angle or perspective if notable. No colons, no keyword lists, no repeated words.

Caption: two to four sentences (about 40 to 80 words) that read as a natural description, not a list.
- Open with the main subject and what is happening, then the setting, then light, weather or time of day, then the mood.
- Use concrete visual details such as light, textures and composition rather than vague praise. Avoid words like "stunning", "beautiful", "breathtaking", "captivating" and "serene".
- Write in the present tense and third person, in plain declarative sentences. Never start with "This image", "This photo", "The photo captures" or "In this picture".
- Add something the title does not say. Do not restate the title or reuse its opening words.
- Work any given names, places or events into the sentences naturally.
- Let the mood come from what is visible, without guessing what people think or feel.
- Use commas and full stops. Do not use em dashes or dashes between clauses.

Keywords: 7 to 15 specific keywords, not counting any names of people or places you were given. Cover each of these where it applies:
- main subject or subjects (for example woman, dog, lighthouse)
- type of photo, always one (for example portrait, landscape, close-up, street)
- clothing style, one general keyword for the whole outfit (for example casual clothing, formal wear, sportswear)
- notable objects (for example kayak, bicycle, umbrella)
- setting and place (for example park, lake, forest, street)
- season and weather (for example autumn, raining)
- time of day and light (for example late afternoon, golden hour)
- action or pose (for example standing, paddling)
- mood or concept (for example relaxed, confident, leisure)

Keyword rules:
- Every main person, animal and object in the photo must also appear as a keyword. Leave out things that are small or far away in the background, even if the caption mentions them, because someone searching for them would not want this photo.
- Use single words or short phrases, as singular nouns, in lower case except for names of people and places.
- For a named person, also give the general word (for example woman, man, child). For a named place, give the type of place (for example park, lake, beach).
- One keyword per idea. Never give variants of the same idea such as "outdoor", "outdoors" and "outdoor setting"; pick one. Do not add a more detailed version of a keyword you already have, such as "autumn colours" next to "autumn" or "pine tree" next to "tree"; pick one.
- Do not pad keywords with words like "setting", "scene", "view" or "area".
- Never give a colour on its own (such as "orange" or "blue") because one object has that colour. Mention an object's colour only when it stands out in the photo, and then give colour and object as one keyword (for example "orange sunglasses"). A colour on its own is only for the main colour or tone of the whole image.
- Describe things, not their properties. Do not give the material, texture, size, shape or pattern of a single object ("wooden", "leather", "small", "round", "striped"), or body parts in an ordinary photo of a person ("hand", "face", "hair"), unless they are the subject, such as a close-up of hands or wood grain.
- Do not give single items of clothing or accessories worn by a person (such as "jeans", "top", "belt", "shoes", "watch"). Give one clothing style keyword for the whole outfit instead. A single item gets its own keyword only when the photo is about it or it stands out, such as a costume, a uniform, a wedding dress or a bright red coat.
- No counts such as "two", "pair" or "group of three".
- No composition words such as "background", "foreground", "horizontal", "copy space" or "bokeh" unless they are a notable feature of the photo.
- One mood word per feeling: not "calm", "peaceful" and "tranquil" together.
- No camera details, links or trademarks, and no generic words like "photo" or "image".
- Final check before answering: every main person, animal and object in the photo has a keyword (for a named person, the general word such as "woman" counts), and nothing small or far away in the background has one.

Describe only what is visible or given to you as fact. Do not invent names of people or places, or dates, that you were not given.]]

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
    if useCurrentData then
        systemPrompt = systemPrompt .. "\n\nThe photo already has a title and caption, given in the request. Improve on them but keep their meaning and any names, places and facts they contain."
    end

    return systemPrompt, userPrompt
end

-- Sends the photo and prompts to Ollama and returns the reply as a table
-- with title, caption and keywords. On failure returns nil, a message for the
-- user, and a kind ("timeout" or "badjson") when retrying might help.
---@param photo LrPhoto The photo to send
---@param prompt string Additional prompt text from the dialog (may be empty)
---@param currentData table (optional) title, caption, contextKeywords, vocabulary, photoFacts, excludeKeys,
---       and thumbnailPath (an already exported thumbnail to reuse; it is not deleted)
---@param useCurrentData boolean (optional) Whether to send the current title and caption
---@param modelName string (optional) Ollama model to use; defaults to the model set at the top of this file
local function sendDataToApi(photo, prompt, currentData, useCurrentData, modelName)
    local useModel = (type(modelName) == "string" and trim(modelName)) or ""
    if useModel == "" then
        useModel = model
    end
    logger:info("Sending data to API using model " .. useModel)
    currentData = currentData or {}

    -- Reuse the thumbnail already made (single-photo dialog) when there is
    -- one; otherwise make one for this request and delete it afterwards
    local encodedImage = currentData.thumbnailPath and base64EncodeImage(currentData.thumbnailPath)
    if not encodedImage then
        local thumbPath = exportThumbnail(photo)
        if not thumbPath then
            return nil, "Could not create a thumbnail for this photo."
        end
        encodedImage = base64EncodeImage(thumbPath)
        LrFileUtils.delete(thumbPath) -- temporary file no longer needed
        if not encodedImage then
            return nil, "Could not read the thumbnail file."
        end
    end
    local url = "http://localhost:11434/api/generate"

    local systemPrompt, userPrompt = buildPrompts(prompt, currentData, useCurrentData)

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

    if noThinkSettingModels[useModel] then
        postData.think = nil
    end

    local response_data

    for _ = 1, 3 do -- up to two retries, each dropping a setting the model rejected
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
    local lastBrace = text:match(".*()}")
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

    if type(response_json.keywords) == "table" then
        -- Split any keyword containing commas ("Oslo, Norway" -> "Oslo",
        -- "Norway"), as Lightroom itself does, so both dialogs save the same
        -- keywords
        local split = {}
        for _, keyword in ipairs(response_json.keywords) do
            if type(keyword) == "string" then
                for _, part in ipairs(splitKeywords(keyword)) do
                    table.insert(split, part)
                end
            end
        end

        -- Enforce the keyword maximum, keeping the model's first (most
        -- relevant) ones. Keywords the plugin drops later anyway (your own
        -- keywords and the photo's place names, in currentData.excludeKeys)
        -- don't count towards it.
        local excludeKeys = currentData.excludeKeys or {}
        local kept, counted = {}, 0
        for _, keyword in ipairs(split) do
            if excludeKeys[normaliseKeyword(keyword)] then
                table.insert(kept, keyword)
            elseif counted < maxKeywords then
                counted = counted + 1
                table.insert(kept, keyword)
            end
        end
        if #kept < #split then
            logger:info("Model returned " .. #split .. " keywords; keeping the first " .. maxKeywords
                .. " (not counting your own keywords and place names)")
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
function normaliseKeyword(keyword) -- assigns the local declared at the top
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

-- Adds place names to a keyword exclusion set, so the photo's location is
-- used as background for the title and caption but not returned as keywords
local function excludePlaces(set, places)
    for _, place in ipairs(places or {}) do
        set[normaliseKeyword(place)] = true
    end
    return set
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
            local trimmed = trim(keyword)
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

        -- filterKeywords never returns an empty keyword
        for _, keyword in ipairs(filterKeywords(keywords, excludeSet, vocabulary)) do
            -- Create child keyword under 'llm' parent (or reuse it if it exists)
            local childKeyword = catalog:createKeyword(keyword, nil, true, llmKeyword, true)
            photo:addKeyword(childKeyword)
            -- Don't call childKeyword:getName() here: a keyword created in
            -- this same catalog write isn't usable until the write ends,
            -- and asking for its name fails ("attempt to index a nil value")
            table.insert(added, keyword)
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

-- Sorts a photo's keywords (from getRawMetadata("keywords")) in one pass:
--   llm      the keywords under the 'llm' parent, as keyword objects
--   llmNames their names
--   userNames  your own keywords (everything except 'llm' and its children)
--   userSet    your own keywords and their synonyms, normalised for matching
local function sortKeywords(keywords)
    local result = { llm = {}, llmNames = {}, userNames = {}, userSet = {} }
    for _, keyword in ipairs(keywords or {}) do
        local name = keyword:getName()
        local parent = keyword:getParent()
        if parent and parent:getName() == "llm" then
            table.insert(result.llm, keyword)
            table.insert(result.llmNames, name)
        elseif name ~= "llm" then
            table.insert(result.userNames, name)
            result.userSet[normaliseKeyword(name)] = true
            local ok, synonyms = pcall(function() return keyword:getSynonyms() end)
            if ok and type(synonyms) == "table" then
                for _, synonym in ipairs(synonyms) do
                    result.userSet[normaliseKeyword(synonym)] = true
                end
            end
        end
    end
    return result
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
        props.prompt = "" -- additional prompt text; the task itself is in the system prompt
        props.useCurrentData = true
        props.useContextKeywords = true
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
            f:static_text{ title = "Additional prompt text (optional):" },
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

    -- Read every photo's details in two catalog calls up front, rather than
    -- several calls per photo. If that fails, each photo is read on its own.
    local okRaw, rawByPhoto = LrTasks.pcall(function()
        return catalog:batchGetRawMetadata(photos, { "keywords", "dateTimeOriginal", "dateTime" })
    end)
    local okFormatted, formattedByPhoto = LrTasks.pcall(function()
        return catalog:batchGetFormattedMetadata(photos,
            { "fileName", "title", "caption", "location", "city", "stateProvince", "country" })
    end)
    if not (okRaw and type(rawByPhoto) == "table") then
        logger:warn("Could not read photo details in bulk: " .. tostring(rawByPhoto))
        rawByPhoto = {}
    end
    if not (okFormatted and type(formattedByPhoto) == "table") then
        logger:warn("Could not read photo details in bulk: " .. tostring(formattedByPhoto))
        formattedByPhoto = {}
    end

    local progress = LrProgressScope({ title = "Lightroom Llama: captioning " .. #photos .. " photos" })
    local succeeded, failures = 0, {}
    local consecutiveTimeouts = 0
    local skipped = 0
    local stoppedEarly

    -- Captions one photo. Returns a message when the whole batch should stop,
    -- otherwise nil.
    local function processPhoto(i, photo, fileName)
        -- This photo's details, from the bulk read when available
        local raw, formatted = rawByPhoto[photo], formattedByPhoto[photo]
        local title, caption
        if formatted then
            title, caption = formatted.title, formatted.caption
        else
            title, caption = photo:getFormattedMetadata("title"), photo:getFormattedMetadata("caption")
        end
        title, caption = title or "", caption or ""

        if options.skipCaptioned and caption:match("%S") then
            skipped = skipped + 1
            logger:info(fileName .. ": skipped (already has a caption)")
            return nil
        end

        local keywords
        if raw then
            keywords = raw.keywords
        else
            keywords = photo:getRawMetadata("keywords")
        end
        local sorted = sortKeywords(keywords)

        local contextList = {}
        if options.useContextKeywords then
            contextList = sorted.userNames
        end
        for _, keyword in ipairs(options.batchKeywords) do
            table.insert(contextList, keyword)
        end
        contextList = filterKeywords(contextList, nil)

        -- Keywords the photo has (or will have) that must not be repeated under 'llm'
        local excludeSet = sorted.userSet
        if options.applyBatchKeywords then
            for _, keyword in ipairs(options.batchKeywords) do
                excludeSet[normaliseKeyword(keyword)] = true
            end
        end

        -- Date and location, given as background; place names never become keywords
        local photoFacts, photoPlaces
        if options.usePhotoFacts then
            photoFacts, photoPlaces = getPhotoFacts(photo, raw, formatted)
            excludePlaces(excludeSet, photoPlaces)
        end

        local useCurrent = options.useCurrentData and (title ~= "" or caption ~= "")
        local requestData = {
            title = title,
            caption = caption,
            contextKeywords = (#contextList > 0) and table.concat(contextList, ", ") or nil,
            vocabulary = frozenVocabularyText,
            photoFacts = photoFacts,
            excludeKeys = excludeSet
        }
        local apiResponse, err, errKind = sendDataToApi(photo, options.prompt, requestData,
            useCurrent, options.model)

        -- A photo that times out or gets a broken reply has one more try
        -- before being counted as failed
        if not apiResponse and (errKind == "timeout" or errKind == "badjson") and not progress:isCanceled() then
            logger:warn(fileName .. ": " .. errKind .. ", retrying once")
            progress:setCaption("Photo " .. i .. " of " .. #photos .. ": " .. fileName .. " (retrying)")
            apiResponse, err, errKind = sendDataToApi(photo, options.prompt, requestData,
                useCurrent, options.model)
        end

        if errKind == "timeout" then
            consecutiveTimeouts = consecutiveTimeouts + 1
        else
            consecutiveTimeouts = 0
        end

        if apiResponse then
            local okWrite, writeErr = LrTasks.pcall(function()
                catalog:withWriteAccessDo("Llama metadata: " .. fileName, function()
                    -- A blank title or caption never replaces the current one
                    if type(apiResponse.title) == "string" and apiResponse.title:match("%S") then
                        photo:setRawMetadata("title", apiResponse.title)
                    end
                    if type(apiResponse.caption) == "string" and apiResponse.caption:match("%S") then
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
        local okName, name = true, formattedByPhoto[photo] and formattedByPhoto[photo].fileName
        if not name then
            okName, name = LrTasks.pcall(function() return photo:getFormattedMetadata("fileName") end)
        end
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
    local catalog = LrApplication.activeCatalog()

    local selectedPhotos = catalog:getTargetPhotos()
    if #selectedPhotos == 0 then
        LrDialogs.message("No photo selected", "Please select one or more photos.", "critical")
        return
    end

    -- More than one photo selected: run in batch mode
    if #selectedPhotos > 1 then
        runBatch(catalog, selectedPhotos)
        return
    end

    local selectedPhoto = selectedPhotos[1]
    local thumbnailPath = exportThumbnail(selectedPhoto)
    local photoFacts, photoPlaces = getPhotoFacts(selectedPhoto)

    LrFunctionContext.callWithContext("showLlamaDialog", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.status = "Ready"
        props.statusColor = colourReady
        props.prompt = "" -- additional prompt text; the task itself is in the system prompt
        props.title = selectedPhoto:getFormattedMetadata("title") or ""
        props.caption = selectedPhoto:getFormattedMetadata("caption") or ""
        local sorted = sortKeywords(selectedPhoto:getRawMetadata("keywords"))
        -- Start with the photo's existing llm keywords
        props.keywords = table.concat(sorted.llmNames, ", ")
        -- Your own keywords, passed to the model as context (editable in the dialog)
        props.contextKeywords = table.concat(sorted.userNames, ", ")
        -- Keywords already on the photo; these are never repeated under 'llm'
        local userKeywordSet = sorted.userSet
        -- Existing llm keywords in the catalog, offered to the model for reuse
        local vocabulary = getLlmVocabulary(catalog)
        local frozenVocabularyText = offerVocabularyToModel and vocabularyText(vocabulary) or nil
        props.useContextKeywords = props.contextKeywords ~= ""
        props.useCurrentData = props.title ~= "" or props.caption ~= ""
        props.usePhotoFacts = photoFacts ~= nil
        props.model = model -- editable in the dialog; not saved
        props.elapsed = "" -- generation time, shown after each run
        props.canGenerate = true -- false while a request is running

        -- "Use current title and caption" only applies when there is a title
        -- or caption to send (batch mode does the same)
        local function sendCurrentData()
            return props.useCurrentData and ((props.title or "") ~= "" or (props.caption or "") ~= "")
        end

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
            }, sendCurrentData())
            props.promptPreview = "SYSTEM PROMPT:\n"
                .. systemPrompt
                .. "\n\nUSER PROMPT:\n" .. userPrompt
                .. "\n\nALSO SENT: the photo (" .. thumbnailSize .. " px), and the required reply format (title, caption, keywords)."
        end
        for _, key in ipairs({ "showPromptPreview", "prompt", "useCurrentData",
                               "title", "caption", "useContextKeywords", "contextKeywords", "usePhotoFacts" }) do
            props:addObserver(key, updatePromptPreview)
        end

        -- Generate: runs the request in the background and fills the boxes
        local function onGenerate()
            props.canGenerate = false
            props.status = "The llama is thinking..."
            props.statusColor = colourBusy
            props.elapsed = ""

            local function showError(message)
                props.elapsed = ""
                logger:error(message)
                props.status = "Error"
                props.statusColor = colourError
                LrDialogs.message("Lightroom Llama", message or "Unknown error", "critical")
            end

            local function generate()
                local startTime = LrDate.currentTime()
                -- Keywords never added under llm: your own keywords and, as
                -- they are background only, the photo's place names (you can
                -- still type a place name into the box yourself)
                local excludeSet = {}
                for key in pairs(userKeywordSet) do
                    excludeSet[key] = true
                end
                if props.usePhotoFacts then
                    excludePlaces(excludeSet, photoPlaces)
                end
                local apiResponse, err, errKind
                for _ = 1, 2 do
                    apiResponse, err, errKind = sendDataToApi(selectedPhoto, props.prompt, {
                        title = props.title,
                        caption = props.caption,
                        contextKeywords = props.useContextKeywords and props.contextKeywords or nil,
                        vocabulary = frozenVocabularyText,
                        photoFacts = props.usePhotoFacts and photoFacts or nil,
                        excludeKeys = excludeSet,
                        thumbnailPath = thumbnailPath
                    }, sendCurrentData(), props.model)
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
                if type(apiResponse.keywords) == "table" then
                    props.keywords = table.concat(filterKeywords(apiResponse.keywords, excludeSet, vocabulary), ", ")
                else
                    props.keywords = ""
                end
                props.elapsed = string.format("%d s", math.floor(LrDate.currentTime() - startTime + 0.5))
                props.status = "Ready"
                props.statusColor = colourReady
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

        local f = LrView.osFactory()
        local c = f:view{ bind_to_object = props, f:row{
            -- Left: the photo and the prompt preview
            f:column{
                width = 400,
                f:picture{ value = thumbnailPath, frame_width = 2, width = 400, height = 400 },
                f:spacer{ height = 10 },
                f:checkbox{ title = "Preview prompt", value = LrView.bind("showPromptPreview") },
                f:spacer{ height = 6 },
                f:scrolled_view{
                    visible = LrView.bind("showPromptPreview"),
                    width = 400,
                    height = 300,
                    horizontal_scroller = false,
                    f:static_text{
                        title = LrView.bind("promptPreview"),
                        width = 370,
                        -- Lightroom sizes this once, when the dialog opens, and
                        -- clips anything longer. The full system prompt alone
                        -- wraps to about 100 lines at this width, so leave room
                        -- for it plus a long user prompt.
                        height_in_lines = 160,
                        selectable = true
                    }
                }
            },
            f:spacer{ width = 10 },
            -- Right: the results, then the options and Generate.
            -- "immediate" keeps the prompt preview in step while typing.
            f:column{
                width = 400,
                f:static_text{ title = "Title:" },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("title"), immediate = true, width = 400 },
                f:spacer{ height = 10 },
                f:static_text{ title = "Caption:" },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("caption"), immediate = true, width = 400, height = 100 },
                f:spacer{ height = 10 },
                f:static_text{ title = "Keywords:" },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("keywords"), width = 400, height = 60 },
                f:spacer{ height = 10 },
                f:separator{ width = 400 },
                f:spacer{ height = 10 },
                f:static_text{ title = "Additional prompt text (optional):" },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("prompt"), immediate = true, width = 400, height = 60 },
                f:spacer{ height = 10 },
                f:checkbox{ title = "Use current title and caption", value = LrView.bind("useCurrentData") },
                f:spacer{ height = 10 },
                f:checkbox{ title = "Use existing keywords as context:", value = LrView.bind("useContextKeywords") },
                f:spacer{ f:label_spacing{} },
                f:edit_field{
                    value = LrView.bind("contextKeywords"),
                    enabled = LrView.bind("useContextKeywords"),
                    immediate = true,
                    width = 400,
                    height = 40
                },
                f:spacer{ height = 10 },
                f:checkbox{
                    title = "Use date and location" .. (photoFacts and (": " .. photoFacts:gsub("\n", "; ")) or " (none recorded)"),
                    value = LrView.bind("usePhotoFacts"),
                    enabled = photoFacts ~= nil,
                    width = 400
                },
                f:spacer{ height = 10 },
                f:separator{ width = 400 },
                f:spacer{ height = 10 },
                f:row{
                    f:static_text{ title = "Model:" },
                    f:edit_field{
                        value = LrView.bind("model"),
                        width_in_chars = 16,
                        tooltip = "Any Ollama vision model you have installed (see 'ollama list')"
                    },
                    f:static_text{
                        title = LrView.bind("elapsed"),
                        width_in_chars = 6,
                        text_color = LrColor(0.0, 0.35, 0.85),
                        tooltip = "Time taken by the last generation"
                    },
                    f:static_text{
                        title = LrView.bind("status"),
                        alignment = "right",
                        width = 160,
                        font = "<system/bold>",
                        text_color = LrView.bind("statusColor")
                    }
                },
                f:spacer{ height = 10 },
                f:row{ f:push_button{
                    title = "Generate",
                    enabled = LrView.bind("canGenerate"), -- off while a request is running
                    action = onGenerate
                } },
                f:spacer{ height = 20 }
            }
        } }

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
            local oldLlmKeywords = sortKeywords(selectedPhoto:getRawMetadata("keywords")).llm
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
                    -- is by name, ignoring capitals only, so duplicate
                    -- variants already on the photo ("tree" and "trees") are
                    -- cut down to the one kept. Removed keywords stay in the
                    -- catalog (Metadata > Purge Unused Keywords clears them).
                    local keep = {}
                    for _, name in ipairs(added) do
                        keep[name:lower()] = true
                    end
                    for _, keyword in ipairs(oldLlmKeywords) do
                        if not keep[keyword:getName():lower()] then
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

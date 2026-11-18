-- Two-column (From / To) editor for the LL Optimize Keywords substitution
-- list. Opened from File > Plug-in Manager and from the LL Optimize Keywords
-- start dialog.
--
-- Load with (passing the caller's import function and plugin path):
--   local SubstitutionEditor = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "SubstitutionEditor.lua"))))(import, _PLUGIN.path)
--
-- Lightroom can't add rows to an open window, so "Add rows" closes the
-- window and reopens it with more empty rows, keeping what was typed.

local import, pluginPath = ...

local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils = import "LrPathUtils"
local LrPrefs = import "LrPrefs"

local Substitutions = (assert(loadfile(LrPathUtils.child(pluginPath, "Substitutions.lua"))))()

-- Empty rows added at the bottom, and by each "Add rows"
local emptyRows = 5

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function addEmptyRows(rows, count)
    for _ = 1, count do
        table.insert(rows, { from = "", to = "" })
    end
end

-- One pass of the window. Returns the button clicked and the rows as typed.
local function showWindow(rows)
    return LrFunctionContext.callWithContext("SubstitutionEditor", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        local lines = {
            f:row {
                f:static_text { title = "From", width_in_chars = 24, font = "<system/bold>" },
                f:static_text { title = "", width_in_chars = 2 },
                f:static_text { title = "To", width_in_chars = 24, font = "<system/bold>" },
            }
        }
        for i, row in ipairs(rows) do
            props["from" .. i] = row.from
            props["to" .. i] = row.to
            table.insert(lines, f:row {
                f:edit_field { value = LrView.bind("from" .. i), width_in_chars = 24 },
                f:static_text { title = "->", width_in_chars = 2, alignment = "center" },
                f:edit_field { value = LrView.bind("to" .. i), width_in_chars = 24 },
            })
        end

        -- Scroll only when the list is too long to fit comfortably
        local list = f:column(lines)
        if #rows > 14 then
            list = f:scrolled_view { width = 520, height = 400, horizontal_scroller = false, list }
        end

        local result = LrDialogs.presentModalDialog {
            title = "LL Optimize Keywords: substitution list",
            contents = f:column {
                bind_to_object = props,
                spacing = f:control_spacing(),
                f:static_text {
                    title = "Each row replaces an llm keyword (From) with another (To) on its photos. "
                        .. "Capitals are ignored. To delete a row, clear both boxes. "
                        .. "LL Optimize Keywords adds a row for every merge you approve.",
                    width = 500, height_in_lines = 3
                },
                list,
            },
            actionVerb = "Save",
            cancelVerb = "Cancel",
            otherVerb = "Add rows"
        }

        local typed = {}
        for i = 1, #rows do
            typed[i] = { from = trim(props["from" .. i]), to = trim(props["to" .. i]) }
        end
        return result, typed
    end)
end

-- Opens the editor. Returns true if the list was saved. Must be called from
-- an async task.
local function edit()
    local prefs = LrPrefs.prefsForPlugin()
    local rows = Substitutions.parse(prefs.substitutions)
    addEmptyRows(rows, emptyRows)

    while true do
        local result, typed = showWindow(rows)
        rows = typed
        if result == "other" then
            addEmptyRows(rows, emptyRows)
        elseif result == "ok" then
            local list, halfFilled = {}, 0
            for _, row in ipairs(rows) do
                if row.from ~= "" and row.to ~= "" then
                    table.insert(list, row)
                elseif row.from ~= "" or row.to ~= "" then
                    halfFilled = halfFilled + 1
                end
            end
            local save = true
            if halfFilled > 0 then
                save = LrDialogs.confirm("Some rows are incomplete",
                    halfFilled .. " row(s) have only From or only To filled in. They will not be saved.",
                    "Save anyway", "Go back") == "ok"
            end
            if save then
                -- format/parse drops rows where From and To are the same word
                prefs.substitutions = Substitutions.format(Substitutions.parse(Substitutions.format(list)))
                return true
            end
        else
            return false
        end
    end
end

-- Number of entries in the saved list
local function count()
    return #Substitutions.parse(LrPrefs.prefsForPlugin().substitutions)
end

-- "3 entries", "1 entry", "no entries"
local function countText()
    local n = count()
    if n == 0 then return "no entries" end
    return n .. (n == 1 and " entry" or " entries")
end

return {
    edit = edit,
    count = count,
    countText = countText
}

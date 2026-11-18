-- Settings shown in File > Plug-in Manager for this plugin

local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local SubstitutionEditor = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "SubstitutionEditor.lua"))))(import, _PLUGIN.path)

return {
    sectionsForTopOfDialog = function(f, propertyTable)
        propertyTable.substitutionCount = "The substitution list has " .. SubstitutionEditor.countText() .. "."
        return {{
            title = "LL Optimize Keywords: substitution list",
            synopsis = SubstitutionEditor.countText(),
            bind_to_object = propertyTable,
            f:static_text {
                title = "Keyword replacements (From -> To) that LL Optimize Keywords applies first. "
                    .. "A row is added for every merge you approve.",
                width_in_chars = 70,
                height_in_lines = 2
            },
            f:row {
                f:push_button {
                    title = "Edit substitution list...",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            if SubstitutionEditor.edit() then
                                propertyTable.substitutionCount =
                                    "The substitution list has " .. SubstitutionEditor.countText() .. "."
                            end
                        end)
                    end
                },
                f:static_text {
                    title = LrView.bind("substitutionCount"),
                    width_in_chars = 40
                },
            },
        }}
    end
}

return {
    VERSION = {
        major = 2,
        minor = 1,
        revision = 0
    },
    LrPluginName = "Lightroom Llama",
    LrPluginDescription = "Generates titles, captions and keywords for your photos with a local Ollama vision model, and merges duplicate keywords (LL Optimize Keywords).",
    -- Kept from the original plugin: changing it would make Lightroom treat
    -- this as a different plugin
    LrToolkitIdentifier = "com.thejoltjoker.lightroom.llama",
    LrPluginInfoUrl = "https://github.com/pattera5/lightroom-llama",
    -- Settings section in File > Plug-in Manager (LL Optimize Keywords substitution list)
    LrPluginInfoProvider = "PluginInfoProvider.lua",
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 5.0,
    LrLibraryMenuItems = {{
        title = "Lightroom Llama...",
        file = "LrLlama.lua",
        enabledWhen = "photosSelected"
    }, {
        -- Works on the whole catalog, so no photo selection is needed
        title = "LL Optimize Keywords...",
        file = "LrOptimizeKeywords.lua"
    }},
    LrExportMenuItems = {{
        title = "Lightroom Llama...",
        file = "LrLlama.lua",
        enabledWhen = "photosSelected"
    }}
}

return {
    VERSION = {
        major = 2,
        minor = 0,
        revision = 0
    },
    LrPluginName = "Lightroom Llama",
    LrPluginDescription = "Generates titles, captions and keywords for your photos with a local Ollama vision model.",
    -- Kept from the original plugin: changing it would make Lightroom treat
    -- this as a different plugin
    LrToolkitIdentifier = "com.thejoltjoker.lightroom.llama",
    LrPluginInfoUrl = "https://github.com/pattera5/lightroom-llama",
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 5.0,
    LrLibraryMenuItems = {{
        title = "Lightroom Llama...",
        file = "LrLlama.lua",
        enabledWhen = "photosSelected"
    }},
    LrExportMenuItems = {{
        title = "Lightroom Llama...",
        file = "LrLlama.lua",
        enabledWhen = "photosSelected"
    }}
}

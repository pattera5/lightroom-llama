<h1 align="center">
  <img src="./screenshot.png" width=400>
  <br/>
  Lightroom Llama
</h1>

<h4 align="center">Generate titles, captions and keywords for your photos with Ollama, directly in Lightroom Classic</h4>
<p align="center">
  <a href="#key-features">Key Features</a> •
  <a href="#how-to-use">How To Use</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#troubleshooting">Troubleshooting</a> •
  <a href="#credits">Credits</a> •
  <a href="#license">License</a>
</p>

> This is a fork of [thejoltjoker/lightroom-llama](https://github.com/thejoltjoker/lightroom-llama), maintained at [pattera5/lightroom-llama](https://github.com/pattera5/lightroom-llama). It adds batch processing, keyword de-duplication, better error handling and a reworked prompt. See [CHANGELOG.md](CHANGELOG.md) for the full list of changes.

## Key Features

- Generate a title, caption and keywords for your photos with Ollama, directly in Lightroom Classic
- Runs entirely on your own computer: no internet required, and your photos aren't uploaded anywhere
- **Single-photo mode** to review and edit the results before saving
- **Batch mode** to caption many photos in one run, with a progress bar and cancel
- **Uses what you already know about a photo:** existing title, caption and keywords are given to the model as facts, so captions name the right people, places and events
- **Keeps your keyword list tidy:** reuses your existing keywords and merges near-duplicates such as "outdoor", "outdoors" and "outdoor setting"
- Generated keywords are filed under an `llm` parent keyword, so they are easy to find, review or remove
- Choose any Ollama vision model from the dialog, without editing code
- Prompt preview and generation timer to help you tune results

## How To Use

### Prerequisites

- Adobe Lightroom Classic
- [Ollama](https://ollama.com/) installed and running on your computer
- An Ollama **vision** model (one that can read images). The default is `qwen3-vl:4b-instruct`.

### Ollama setup

1. Open a terminal
2. Install [Homebrew](https://brew.sh/) if you don't have it already
   1. `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
3. `brew install ollama`
4. Start Ollama: `ollama serve` (or open the Ollama app)
5. Download the default model: `ollama pull qwen3-vl:4b-instruct`

Other vision models work too, for example `qwen3-vl:8b-instruct`, `gemma4:e4b`, `gemma4:12b` or `gemma3:12b`. Use the `-instruct` versions of Qwen models; the plain tags are "thinking" builds and are much slower.

For the latest instructions on installing and running Ollama, see [the Ollama repository](https://github.com/ollama/ollama).

### Installation

1. Clone or download the latest version from [pattera5/lightroom-llama](https://github.com/pattera5/lightroom-llama)
2. Open Adobe Lightroom Classic
3. Go to File > Plug-in Manager
4. Click the "Add" button in the bottom left
5. Navigate to the downloaded plugin folder and select the `.lrplugin` folder
6. Click "Done" to close the Plug-in Manager

After updating the plugin files, select the plugin in the Plug-in Manager and click **Reload Plug-in**.

### Single-photo mode

Select one photo and choose **Library > Plug-in Extras > Lightroom Llama...**

1. Optionally edit the prompt and options:
   - **Use current title and caption:** the model improves on the existing ones and keeps their names and facts
   - **Use existing keywords as context:** pre-filled with the photo's own keywords; edit the list to add hints such as a place or a person's name
   - **Use system prompt:** the full writing guidelines (recommended)
   - **Model:** any installed Ollama vision model
2. Click **Generate**. The time taken appears in blue next to the Model box.
3. Review and edit the title, caption and keywords, then click **Save**.

Tick **Preview prompt** under the photo to see exactly what will be sent to the model.

### Batch mode

Select more than one photo and choose the same menu item.

1. Set the prompt and options (they apply to every photo, but each photo uses its own title, caption and keywords).
2. Optionally enter **Keywords for this batch**, such as an event or place. These are given to the model as facts for every photo. With **Also add these keywords to every photo** ticked, they are also added to each photo as your own keywords.
3. Click **Generate**. Each photo is captioned and saved straight away.

Notes:
- Each photo is saved as its own step, so recent ones can be reverted with Edit > Undo.
- A blank result never wipes an existing title or caption.
- If Ollama isn't running or the model is missing, the batch stops at the first photo.
- A summary at the end lists any photos that failed.

### How keywords are handled

- Keywords already on a photo are never repeated under `llm`.
- Your existing `llm` keywords are offered to the model so it reuses your wording.
- Near-duplicates are merged before saving. Matching ignores capitals, plurals (including irregular ones such as leaves/leaf and people/person) and padding words such as "setting", "scene" and "view".
- When a generated keyword matches one you already have, your existing spelling is used.
- Em dashes are removed from titles and captions.

To clean up old duplicate keywords, remove them from your photos and choose **Metadata > Purge Unused Keywords**.

## Configuration

Settings at the top of `LrLlama.lua`:

| Setting | Default | Purpose |
|---|---|---|
| `model` | `qwen3-vl:4b-instruct` | Default model shown in the dialog |
| `thumbnailSize` | `768` | Longest side in pixels of the image sent to the model. Larger shows more detail but is slower. |

The model is kept loaded in Ollama for 30 minutes between requests, and uses a temperature of 0.3 for consistent results.

## Troubleshooting

**Logs** are written to:
- macOS: `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrLlama.log`
- Windows: `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\LrLlama.log`

Watch it live on macOS with `tail -f ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrLlama.log`.

| Message | Cause and fix |
|---|---|
| Could not reach Ollama | Ollama isn't running. Start it with `ollama serve` or the Ollama app. |
| Ollama error: model '...' not found | The model isn't downloaded. Run `ollama pull <model>` or pick an installed model from `ollama list`. |
| Ollama error: structured output is unavailable | Handled automatically: the plugin retries without JSON mode. Avoid `:cloud` and `-mlx` tags if problems continue. |
| The model's reply wasn't valid JSON | The model ignored the format. Try another model, or check the full reply in the log. |

**Performance:** Ollama's reply in the log includes timings (`prompt_eval_duration` for reading the image and prompt, `eval_duration` for writing the reply, in nanoseconds). Building standard-sized previews in Lightroom before a large batch also helps.

## TODO

- [x] Add support for more LLM models
- [x] Implement batch processing for multiple photos
- [x] Improve error handling and user feedback
- [ ] Add customizable prompt templates
- [ ] Create settings panel for model configuration
- [ ] Merge true synonyms (for example "woods" and "forest")
- [ ] Clean up temporary thumbnail files

## Credits

- **Original plugin:** [thejoltjoker/lightroom-llama](https://github.com/thejoltjoker/lightroom-llama) by Johannes ([thejoltjoker](https://github.com/thejoltjoker))
- **Fork and enhancements:** [pattera5](https://github.com/pattera5), developed with the assistance of [Claude](https://claude.ai) by Anthropic
- **JSON encoder/decoder (`JSON.lua`):** Jeffrey Friedl ([regex.info](http://regex.info/blog/))
- [Ollama](https://ollama.com/)

## More from the original author

- [Lightroom Power Collection](https://github.com/thejoltjoker/lightroom-power-collection) - Lightroom plugin to create a smart collection to semi-automate publishing.
- [Lightroom Workflow](https://github.com/thejoltjoker/lightroom-workflow) - Lightroom workflow and presets for editing, organizing and exporting photos.
- [ChatGPT for Maya](https://github.com/thejoltjoker/chatgpt-for-maya) - Autodesk Maya plugin for context aware chatting with ChatGPT.

## License

This project is licensed under the [MIT License](LICENSE), the same license as the original project.

- Copyright (c) 2024 Johannes (original plugin)
- Copyright (c) 2026 pattera5 (fork and enhancements)

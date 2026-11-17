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
- **Uses what you already know about a photo:** existing title, caption, keywords, capture date and location are given to the model as facts, so captions name the right people, places, seasons and events
- **Keeps your keyword list tidy:** merges near-duplicates such as "outdoor", "outdoors" and "outdoor setting" into your existing keywords
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
   - **Use date and location:** shows when and where the photo was taken, from its metadata; greyed out if none is recorded. These are background for the title and caption: place names such as the city or state are not added as keywords (generic words such as "park" still are).
   - **Use system prompt:** the full writing guidelines (recommended)
   - **Model:** any installed Ollama vision model
2. Click **Generate**. The button is greyed out until the reply arrives, then the time taken appears in blue next to the Model box. A blank title or caption in the reply leaves the current one in place.
3. Review and edit the title, caption and keywords, then click **Save**. The photo's `llm` keywords are set to exactly what is in the Keywords box: any you removed from the box are removed from the photo, and duplicate variants already on it (such as "tree" and "trees") are cut down to one. Save is greyed out while Generate is running.

Tick **Preview prompt** under the photo to see exactly what will be sent to the model.

### Batch mode

Select more than one photo and choose the same menu item.

1. Set the prompt and options (they apply to every photo, but each photo uses its own title, caption, keywords, date and location). Tick **Skip photos that already have a caption** to process only new photos.
2. Optionally enter **Keywords for this batch**, such as an event or place. These are given to the model as facts for every photo. With **Also add these keywords to every photo** ticked, they are also added to each photo as your own keywords.
3. Click **Generate**. Each photo is captioned and saved straight away.

Notes:
- Each photo is saved as its own step, so recent ones can be reverted with Edit > Undo.
- A blank result never wipes an existing title or caption.
- A photo that times out or returns a broken reply is retried once.
- A photo that hits an unexpected error is listed as failed and the batch moves on to the next one.
- If Ollama isn't running or the model is missing, the batch stops at the first photo. It also stops after 3 timeouts in a row.
- A summary at the end shows skipped photos and lists any that failed.

### How keywords are handled

- Keywords already on a photo are never repeated under `llm`.
- Place names from the photo's location, city, state and country fields are not added as keywords; they are used in the title and caption only.
- The model is asked to cover main subject, type of photo (always one, such as portrait or landscape), clothing and objects, setting, season and weather, time of day and light, action or pose, and mood, with 7 to 15 keywords. Anything past 15 is dropped. Your own keywords and place names don't count towards the 7 to 15, as they are removed anyway.
- For a named person the model also gives the general word (woman, man, child), and for a named place the type of place (park, lake, beach), so the photo can be found both ways.
- The model is asked to describe things, not their properties:
  - no colour on its own because one object has that colour; a notable colour is joined to its object ("orange sunglasses", not "orange"), and a colour on its own is only for the main colour or tone of the whole image
  - no material, texture, size, shape or pattern of a single object ("wooden", "small", "striped"), and no body parts in an ordinary photo of a person, unless they are the subject
  - no counts ("two", "pair"), no composition words ("background", "bokeh") unless notable, and one mood word per feeling

  These are prompt rules, so a small model may occasionally ignore them.
- Near-duplicates are merged before saving, including against all your existing `llm` keywords. Matching ignores capitals, plurals (including irregular ones such as leaves/leaf and people/person) and padding words such as "setting", "scene" and "view".
- When a generated keyword matches one you already have, your existing spelling is used.
- Words such as shorts, glasses, jeans and news are treated as their own words, not plurals.
- A keyword containing commas, such as "Oslo, Norway", is split into separate keywords.
- Em dashes (and dashes used between clauses) are removed from titles and captions.

To clean up old duplicate keywords, remove them from your photos and choose **Metadata > Purge Unused Keywords**.

## Configuration

Settings at the top of `LrLlama.lua`:

| Setting | Default | Purpose |
|---|---|---|
| `model` | `qwen3-vl:4b-instruct` | Default model shown in the dialog |
| `thumbnailSize` | `768` | Longest side in pixels of the image sent to the model. Larger shows more detail but is slower. |
| `requestTimeout` | `180` | Seconds to wait for Ollama to answer one photo |
| `maxKeywords` | `15` | Most keywords kept from each reply |
| `maxReplyTokens` | `600` | Most tokens a reply may use, so a model stuck repeating itself stops quickly |
| `offerVocabularyToModel` | `false` | List your existing `llm` keywords in the prompt. Small models tend to copy unrelated keywords from it, so leave off unless using a larger model. |

Requests also keep the model loaded for 30 minutes, use a temperature of 0.3, fix the context size at 8,192 tokens and switch off "thinking".

## Troubleshooting

**Logs** are written to:
- macOS: `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrLlama.log`
- Windows: `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\LrLlama.log`

Watch it live on macOS with `tail -f ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrLlama.log`.

| Message | Cause and fix |
|---|---|
| Could not reach Ollama | Ollama isn't running. Start it with `ollama serve` or the Ollama app. |
| Ollama took longer than 180 seconds to answer | Ollama is running but slow or stuck. Retried once automatically; if it persists, restart Ollama. |
| Ollama error: model '...' not found | The model isn't downloaded. Run `ollama pull <model>` or pick an installed model from `ollama list`. |
| Ollama error: structured output is unavailable | Handled automatically: the plugin retries without JSON mode. Avoid `:cloud` and `-mlx` tags if problems continue. |
| The model's reply wasn't valid JSON / was cut off | The model broke format or got stuck repeating itself. Retried once automatically; the full reply is in the log. |
| Ollama returned an empty response / spent its whole reply thinking | The model's "thinking" used up the reply. Use a non-thinking model, such as an `-instruct` build. |
| Could not save to the photo | Lightroom was busy (for example another plugin or a sync was writing to the catalog). Click Save again in a moment. |

**Place names missing:** the plugin reads Lightroom's location, city, state and country fields, not raw GPS. Fill those fields from the Map module first.

**Performance:** Ollama's reply in the log includes timings (`prompt_eval_duration` for reading the image and prompt, `eval_duration` for writing the reply, in nanoseconds). Building standard-sized previews in Lightroom before a large batch also helps.

## TODO

- [x] Add support for more LLM models
- [x] Implement batch processing for multiple photos
- [x] Improve error handling and user feedback
- [ ] Add customizable prompt templates
- [ ] Create settings panel for model configuration
- [x] Clean up temporary thumbnail files
- [ ] Merge true synonyms (for example "woods" and "forest")
- [ ] Tool to merge duplicate `llm` keywords already in the catalog
- [ ] Put processed batch photos in a review collection
- [ ] Decide whether single-photo Save should keep an `llm` keyword that has the same name as one of your own keywords on the photo (at the moment the `llm` copy is removed)

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

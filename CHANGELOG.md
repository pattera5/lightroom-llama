# Lightroom Llama: changelog

## 2.0.0 (17 November 2026)

First release of this fork, compared with the original plugin. Most changes are to `LrLlama.lua`. `JSON.lua` is unchanged.

### Bug fixes

- **"nil passed to JSON:decode()" crash fixed.** The plugin assumed Ollama always returns a result. When Ollama reports an error instead (for example, model not found), it now shows Ollama's actual message rather than crashing.
- **Thumbnail timing fixed.** The plugin waits (up to 15 seconds) for Lightroom to deliver the thumbnail before using it.
- **Full-quality thumbnail.** Lightroom may first deliver a quick low-quality image. The plugin reads each image's size, keeps the largest, and waits up to 5 seconds after the first for a full-size one. The log notes when only a smaller image was available.
- **Error handling in the dialog.** A failed Generate shows a red "Error" status and a message explaining the problem.
- **Empty title or caption** no longer breaks the prompt.
- **JSON fallback.** If a model doesn't support Ollama's JSON mode ("structured output is unavailable"), the request is retried without it, and the JSON is extracted from the reply, ignoring surrounding text, code fences or `<think>` blocks.
- **Request timeouts.** Each request may take up to 180 seconds (`requestTimeout`). A timeout is reported as such, not as "Ollama isn't running".
- **Broken or runaway replies.** Replies are capped at 600 tokens (`maxReplyTokens`) with a mild repetition penalty, so a model stuck repeating itself stops quickly. A broken or empty reply is retried once automatically, and the log records why it failed.
- **Thinking switched off.** Requests ask Ollama to turn off step-by-step "thinking" (Gemma 4, Qwen thinking builds), which could use up the whole reply and leave the answer empty. Models without a thinking mode that reject the setting are retried without it.
- **Temporary thumbnails deleted** after each request and when the single-photo dialog closes.
- **Log location comment updated** for Lightroom Classic 14 and later:
  - macOS: `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LrLlama.log`
  - Windows: `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\LrLlama.log`

### Model and request

- **Default model** changed from `gemma3:12b` to `qwen3-vl:4b-instruct`.
- **Editable Model box** in both dialogs. The value lasts for that dialog only and is not saved.
- **Model kept loaded** for 30 minutes between requests (`keep_alive = "30m"`).
- **Exact reply format.** Ollama is given a schema requiring a `title` (string), a `caption` (string) and `keywords` (list of strings).
- **Model settings:** temperature 0.3 for steadier results, context size fixed at 8,192 tokens so the model isn't reloaded between requests.
- **Image size** raised from 512 to 768 px, set by `thumbnailSize` near the top of the file.
- **Smaller log.** The encoded image is no longer logged. The prompts and Ollama's full reply (including timings) still are.

### Prompt

- **Rewritten system prompt.** About a third of the original length, sample sunset-and-beach answer removed, asks for English.
- **Caption guidance:**
  - order: main subject and action, then setting, then light, weather or time of day, then mood
  - concrete visual details; words like "stunning", "beautiful", "breathtaking", "captivating" and "serene" discouraged
  - present tense, third person; no openings like "This image shows" or "The photo captures"
  - adds something the title doesn't say
  - works given names, places and events in naturally
  - mood taken from what is visible, without guessing feelings
  - about 40 to 80 words
- **No em dashes.** Forbidden in the prompt, and any that appear in the title or caption are replaced with commas in code (including `--` and spaced en dashes used as a dash). A dash at the very end is removed rather than left as a trailing comma. Hyphens and number ranges are untouched.
- **Existing keywords as context.**
  - Single mode: a checkbox and editable box, pre-filled with the photo's own (non-`llm`) keywords.
  - Batch mode: an option to use each photo's own keywords.
  - The model treats them as verified facts and does not repeat them.
- **Date and location as context.** When the photo was taken, and its location, city, state and country fields, are given to the model as accurate facts for season, time of day and place names. A checkbox in each dialog, on by default when the photo has them.
- **Keyword categories.** The model is asked to cover, where they apply: main subject and type of photo; clothing and notable objects; setting and place; season, weather and light; action or pose; mood or concept.
- **Keyword rules** (under their own heading): 7 to 15 keywords, everything named in the caption also a keyword, singular nouns, lower case except names, one keyword per idea, no padding words such as "setting", "scene", "view" or "area", no camera details or generic words.
- **Existing-keyword list removed from the prompt.** An earlier version listed up to 200 existing `llm` keywords for the model to reuse. The small model copied unrelated keywords from it (from other photos), so it is off by default (`offerVocabularyToModel = false`). Near-duplicate matching in code still uses all existing keywords.

### Keyword clean-up in code

- **No repeats of your own keywords.** Keywords already on a photo (and their synonyms) are never added again under `llm`.
- **Near-duplicates merged.** Matching ignores capitals, plural endings (including irregular plurals such as leaves/leaf, people/person, children/child, movies/movie, tomatoes/tomato and buses/bus) and filler words. "outdoors", "outdoor setting" and "Outdoor" become one keyword.
- **Plural-looking words kept apart.** Words such as shorts, glasses, jeans, news and species are not reduced to a different word ("shorts" no longer matches "short", "glasses" no longer matches "glass").
- **Keywords containing commas split.** A reply keyword such as "Oslo, Norway" becomes "Oslo" and "Norway", as Lightroom does, so single and batch mode save the same keywords.
- **Existing spelling reused.** When a generated keyword matches an existing `llm` keyword, the existing one is used rather than a new variant being created.
- **Plainer variant kept.** When a reply contains two new variants of one idea, the shorter is kept ("forest" over "forest scene").
- **Keyword cap enforced.** Only the first 15 keywords of a reply are kept (`maxKeywords`).

### Single-photo dialog

- **Timer.** Generation time in whole seconds, shown in blue to the right of the Model box after each successful run.
- **Preview prompt.** A checkbox under the photo (off by default) showing a read-only, scrollable view of exactly what will be sent. It reflects the Prompt box and all checkboxes, and updates as you type in the Prompt box.
- **Use date and location** checkbox, showing the details found for the photo.
- **Save matches the Keywords box.** Save adds the keywords in the box under `llm` and removes any `llm` keywords on the photo that are no longer in the box (for example after Generate replaced the list, or you deleted one). Duplicate variants already on the photo (such as "tree" and "trees") are cut down to the one kept. Removed keywords stay in the catalog until purged.
- **Blank results ignored.** An empty title or caption from the model no longer clears the box.
- **Generate and Save disabled while generating,** so a second click can't start a competing request and Save can't store the old text while a new reply is on its way.
- **Save errors reported.** If Lightroom can't save (for example the catalog is busy), a message says so instead of Lightroom's raw error.

### Batch mode (new)

- Used automatically when more than one photo is selected.
- **Dialog:** prompt, "Use each photo's current title and caption", "Use each photo's existing keywords as context", "Use each photo's date and location", "Skip photos that already have a caption", "Use system prompt", editable Model box.
- **Keywords for this batch:** given to the model as context for every photo. With "Also add these keywords to every photo" ticked (default), they are also added to each photo as your own top-level keywords, not under `llm`.
- **Running:**
  - progress bar with cancel
  - each photo saved as its own Undo step
  - a blank result never wipes an existing title or caption
  - a photo that times out or returns a broken reply is retried once
  - a photo that hits an unexpected error is listed as failed and the batch carries on, instead of stopping with Lightroom's raw error
  - stops at the first photo if Ollama can't be reached or the model is missing, or after 3 timeouts in a row
  - summary at the end, with skipped photos and any failures (details in the log)
- **Consistent keywords across the batch.** Keywords created for one photo are matched against for later photos.

### Project files

- **`Info.lua`:** real description, version 2.0.0, and the info link now points to this fork. The plugin identifier is unchanged so Lightroom still sees it as the same plugin.
- **Removed** `request.txt` (an old test request) and the GitHub Pages workflow inherited from the original project.

## Known limitations

- True synonyms (for example "woods" and "forest") are not merged.
- Words sharing a root may still be merged when the meaning differs, unless they are in the plugin's list of exceptions.
- Photos with GPS coordinates but empty location fields get no place name; fill the fields from Lightroom's Map module first.
- The capture time comes from the camera clock, so it is wrong if the camera was set wrong.
- Keyword examples in the prompt can occasionally be copied onto photos where they don't belong.

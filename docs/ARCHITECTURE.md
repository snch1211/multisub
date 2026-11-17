# MultiSub architecture

This document describes how MultiSub is put together after the 2026-11 refactor
(three subtitle modes, bring-your-own-key cloud engines, App Store build). It is
the contract between the three moving parts — the web extension, the native
Safari extension handler, and the host app — so read it before changing any
message shape.

```
 Netflix tab                         Safari extension process          Host app
┌──────────────────────────────┐    ┌──────────────────────────┐    ┌─────────────────────┐
│ inject.js  (page world)       │    │ SafariWebExtensionHandler│    │ SwiftUI app         │
│  hooks JSON.parse / .json()   │    │  native actions ↓        │    │  onboarding         │
│  → subtitle track list + cues │    │ Translator (actor)       │    │  AI engine settings │
│ content.js (isolated world)   │    │  ├ local: MLX + Gemma    │    │  model downloads    │
│  modes, alignment, overlay    │    │  └ cloud: CloudLLMClient │    │  styles / cache /   │
└──────────────┬───────────────┘    └────────────▲─────────────┘    │  vocabulary         │
               │ runtime.Port "multisub"         │ sendNativeMessage └──────────▲──────────┘
┌──────────────▼───────────────┐                 │                              │
│ background.js                ├─────────────────┘        App Group container + shared keychain
│  job queue, caching, batching│                (config.json, models/, vocab*/, API keys)
└──────────────────────────────┘
```

## 1. Subtitle modes

The user picks one of three modes the first time they use MultiSub (in the app's
onboarding or the popup), and can switch at any time from the popup.

| Mode id     | Name (UI)          | What is shown                                                    | Needs an AI engine |
|-------------|--------------------|------------------------------------------------------------------|--------------------|
| `netflix`   | Netflix 雙語字幕   | Original line + Netflix's own subtitle in the second language    | No                 |
| `translate` | AI 翻譯雙語字幕    | Original line + AI translation of it                             | Yes                |
| `annotate`  | 生字標註           | Original line only, with short glosses after uncommon words      | Yes                |

### Tracks

* **Primary track** (the language being watched/learned): the subtitle track
  currently selected in Netflix's player. If Netflix subtitles are off, or the
  selected track is already in the target language, fall back to the track in
  the audio language, then English, then the first full (non-forced) track.
* **Second-language track**: Netflix's track in the user's target language
  (non-forced; full subtitles preferred over closed captions).

### Per mode

* `netflix` — both lines come straight from Netflix. Each track is rendered on
  its own timeline (no alignment), so nothing is lost when Netflix splits lines
  differently between languages. If Netflix has no track in the target
  language, the overlay says so and the popup offers to switch to `translate`.
* `translate` — the primary track is translated in batches. The official
  second-language track, when present, is aligned to the primary cues and used
  only as a terminology reference (names, recurring terms), never copied.
* `annotate` — see §2.

### Layout

`settings.mergedMode` (default **on** for new installs): Netflix's own subtitle
element is hidden and MultiSub renders every line itself, so the two lines
never collide with Netflix's positioning. With it off, only the second line is
drawn and Netflix keeps drawing the first, but only while Netflix is drawing
the primary track: `inject.js` reports Netflix's active track (`active-track`,
with `forced` for forced narratives), and when Netflix's subtitles are off,
forced-only, in the target language or a different track than the primary,
MultiSub draws both lines instead. `annotate` always uses the merged layout
because it replaces the original line.

Netflix's own subtitles are hidden only while MultiSub has something to draw
in their place (its own cues, or the DOM-fallback text outside `netflix`
mode), so a failed track capture never leaves the viewer with no subtitles.

## 2. Annotate mode (生字標註)

Goal: one subtitle line, in the original language, where only the words a
learner at their level would likely stumble on carry a short gloss in the
target language — chosen to fit *this* line's meaning, taken from Netflix's
official translation wherever possible. Speed matters more than coverage: a
gloss that makes the viewer stop and think is worse than no gloss.

Pipeline (per episode, in the background, starting at the current playback
position):

1. **Align** the primary cues with the official target-language cues by time
   overlap (`MS.alignCues`). Each primary cue gets the official text shown at
   the same moment, or null.
2. **Chunk by scene**: consecutive cues, at most 16 per request, cut early at
   gaps longer than 5 s once a chunk has 8+ cues. The two cues before a chunk
   are sent as read-only context so a chunk boundary never strands a pronoun or
   a split sentence.
3. **Pre-select candidates** (English sources only): tokens whose CEFR level is
   above the learner's level (`cefr-wordlist-en.txt`), plus unlisted words that
   look rare (alphabetic, ≥ 5 letters, not capitalised mid-line, not a
   stopword). Naive lemmatisation (`-s/-es/-ed/-ing/-ly/-er/-est`, `-ies→-y`,
   doubled consonants). This keeps density consistent and stops the model from
   glossing words the learner obviously knows. Other source languages skip this
   step and rely on the model's judgement of the stated level.
4. **One LLM call per chunk**. The model sees every line with its aligned
   official line and the candidate list, and returns JSON
   `[{"i": 3, "term": "come up with", "gloss": "想出"}]`. Rules in the prompt:
   at most 2 picks per line (many lines get none); prefer idioms/phrasal verbs
   as a whole; skip names, interjections, numbers and words obvious from
   context; the gloss is the meaning *in this line*, 1–6 CJK characters or ≤ 3
   words, reusing the official subtitle's wording for that idea when it has
   one; never translate the whole line.
5. **Validate**: the term must occur in its line (case-insensitive, word
   boundaries), the gloss must be short and differ from the term; invalid items
   are dropped, never repaired. A malformed response is retried once, then the
   chunk is stored as "no annotations" rather than failing the episode.
6. **Render**: `term` is underlined subtly and followed by the gloss in a
   smaller, accent-coloured span. Each term is glossed at most 3 times per
   episode (by cue order) so repeated words stop cluttering the line.

Why this split: aligning in JS is deterministic and free; candidate filtering
in Swift keeps the prompt small and the selection stable between runs; the
model only does what needs judgement (which picks matter, which sense, which
wording) with the official translation in front of it, which is what keeps
glosses from drifting away from what the scene means.

## 3. AI engines

`config.engine`:

* `auto` (default) — cloud if an API key is saved for the selected provider
  and the user has agreed to send subtitles there (below), otherwise the local
  model if it is downloaded, otherwise "not ready".
* `local` — MLX + Gemma, downloaded once from Hugging Face (Apple silicon).
  Only the app's explicit download (and the size lookup for a model shown as
  not downloaded) contacts Hugging Face. Loading reads the snapshot folder
  `MultiSubPaths.modelSnapshotDirectory` finds complete on disk
  (`LocalModelFolder`), with no network request in either process; a missing
  or incomplete model is `model-not-ready`, never a download. Complete means
  every file `ModelDownloader` listed before it stored the first one
  (`models--<org>--<name>/.multisub-expected-files/<commit>.json`); a
  snapshot without that list (an older build's download, or files put there
  by hand) needs `config.json`, `tokenizer.json`, `tokenizer_config.json`
  and every weight shard.

  Downloads (`ModelDownloader`, app only) resume: a later attempt, in this
  run or after a relaunch, skips the files already in the snapshot and
  resumes the one that was in flight, which waits as `<etag>.partial` in
  the model's partial folder `models/.download-tmp/<org>--<name>/`
  (`MultiSubPaths.modelPartialDirectory`). That folder is removed once every
  file is stored; per-attempt folders named by a UUID, left by older builds,
  are removed when the next download starts. A write that fails (a full
  disk) ends the download at once with 「磁碟空間不足，清出空間後再試一次」
  rather than retrying, and keeps the bytes written for 繼續下載
  (`StreamingDownloadDelegate` uses FileHandle's throwing calls; the older
  ones raise an exception Swift can't catch, which quit the app). A
  download whose remaining bytes exceed the volume's
  `volumeAvailableCapacityForImportantUsage` is refused with the same
  message before it fetches anything. For a model that isn't
  complete, 一般設定 shows what its repo folder and partial folder hold as
  「下載未完成（佔用 …）」 (`MultiSubPaths.unfinishedDownloadBytes`; hidden
  files, the expected-files list among them, don't count, so a download that
  stopped before any data shows nothing to delete), labels the button
  繼續下載 (重試下載 after a failure that left nothing, else 下載), and offers a
  trash button. Deleting a model, downloaded or not, removes both folders;
  it is refused while that model downloads or is loaded in the app, or while
  the app's `Translator` is busy. Models found only on disk (not in the
  catalog) are listed whenever either folder holds data
  (`MultiSubPaths.modelIDsOnDisk`).
* `cloud` — the user's own API key (BYOK); "not ready" without consent.

Cloud providers (`CloudProvider`): `anthropic`, `openai`, `openrouter`,
`gemini` (OpenAI-compatible endpoint), `custom` (any OpenAI-compatible base
URL, e.g. a local LM Studio/Ollama server). Requests are made from Swift with
`URLSession` in whichever process needs them (the extension handler for
subtitles, the app for vocabulary and "test"). Keys are stored in the shared
keychain access group `$(AppIdentifierPrefix)$(MULTISUB_BUNDLE_ID).shared`
(data-protection keychain), one item per provider, and are never sent back to
JavaScript. Keys are entered only in the app (`EngineSetupView`, in
onboarding and 一般設定), which is also the only place that picks the
provider and model, tests a setup and asks for consent. The toolbar popup
only shows the engine in use (from `ping`) or, when there is none, a button
that opens the app's settings (`open-app {destination: "general"}`). The
engine is configured in the app only, and the extension cannot change it:
the native handler has no action that sets the engine, provider, model, key
or consent, or that tests a setup or lists models (§5.2), so no extension
context can save a key or record consent without the app's UI.

**Consent (App Review 5.1.2(i)).** `config.cloudConsent` maps a provider id to
when (ms) the user agreed that subtitle text may be sent there directly from
this Mac. For `custom` the consent belongs to the address: the key is
`custom:` plus the normalized base URL (`CloudSettings.normalizedBaseURL`:
scheme and host lowercased, no default port, no trailing slash), so agreeing
to one server never covers another. A consent saved under plain `custom` by
an older build moves to the base URL saved in the same config when it's read.
`Translator.resolveEngine` treats settings without an entry as not
ready (`engine-not-ready`; `auto` falls through to the local model), so no
subtitle text leaves the Mac before the user has agreed. Consent is recorded
by the app's confirmation alert, which asks again for every custom address
not agreed to yet (`EngineSetupView` keys it with
`MultiSubConfig.consentKey`), and nothing else records it; it is never
removed by switching away.
The alert names the provider, or 「你填的 API 網址」 plus the address as typed
for `custom`. Swift records the consent and sends with Foundation, while a
person reading the address, or a WHATWG parser like the one the popup used
when it had a consent step, can take some addresses for another server, so
a custom address must be one both read as the same server
(`CloudSettings.baseURLProblem`): http(s), a host of
ASCII letters, digits, `.`, `-`, `_` (a numeric one as plain dotted IPv4) or
a bracketed IPv6 address, an optional port, and no credentials, percent
escapes, backslash, whitespace or control characters anywhere
(`http://localhost:1234\@evil.example/v1` is localhost to WHATWG and
evil.example to Foundation). The app refuses any other address with a zh-TW
message, and `CloudLLMClient` sends nothing to one saved by an older build.
tests/native checks that WHATWG and Foundation find the same host and port
for the addresses it accepts, and how consent is keyed per address,
including a legacy `custom` record moving to the saved base URL.

**Test before save.** The app tests what was typed before saving anything
(`Translator.testEngine(client:)`). Only a passing test saves the key,
engine and cloud settings (and consent), so a typo never replaces a working
engine. The test sends one fixed English sentence, never subtitle text,
which is why it needs no consent; the app asks for consent before its test.

**Refusals and reasoning.** A provider refusal (Anthropic `stop_reason:
"refusal"`, OpenAI-style `content_filter` / `message.refusal`) or an empty
answer cut off by the output limit is `CloudLLMError.refused`
(`provider-error`). `translate` then redoes the batch one line per call and
returns `""` for a refused line only; background.js keeps such lines `null`,
so they are asked again by a later job instead of being cached blank.
`annotate` and `extract-glossary` treat a refusal as "nothing found". Leading
`<think>…</think>` / `<thinking>…</thinking>` blocks in OpenAI-compatible
replies are stripped before parsing.

**Local model lifecycle.** Concurrent requests share one in-flight model load
instead of each loading the weights. A load for another model, or `unload()`,
cancels the load in flight (waiters get `CancellationError`, reported as
`<action>-failed`), so an unload during a cold start sticks. The idle unload
never runs while a request or a load is in progress.

Both engines run the same prompts (`Prompts.swift`); `Translator` only decides
where the text goes.

Provider defaults (checked against each provider's docs on 2026-11-16; the
model picker also lists whatever the provider's `/models` endpoint returns):

| Provider   | Endpoint                                                        | Default model           | Latency settings                                   |
|------------|-----------------------------------------------------------------|-------------------------|----------------------------------------------------|
| Anthropic  | `POST https://api.anthropic.com/v1/messages`, `anthropic-version: 2026-10-21` | `claude-haiku-5-5` | `output_config.effort: "low"`; never send `temperature` |
| OpenAI     | `POST https://api.openai.com/v1/chat/completions`               | `gpt-6-luna`            | `reasoning_effort: "none"`, `max_completion_tokens` |
| OpenRouter | `POST https://openrouter.ai/api/v1/chat/completions`            | `anthropic/claude-haiku-5.5` | `reasoning: {effort: "low"}`                  |
| Gemini     | `POST https://generativelanguage.googleapis.com/v1beta/openai/chat/completions` | `gemini-3.1-flash-lite` | `reasoning_effort: "minimal"`        |
| Custom     | `<base URL>/chat/completions` (OpenAI-compatible)               | user-supplied           | none                                               |

Optional latency parameters are dropped and the request retried once when a
model answers 400 to them, so a user-picked model with different rules still
works. Recommended picks shown in the UI: fastest (default above), balanced
(`claude-sonnet-5-5`, `gpt-6.1-terra`), best quality (`claude-opus-5-5`,
`gpt-6.1-sol`).

## 4. Settings ownership

| Data                                   | Owner / storage                                   | Synced how                                    |
|----------------------------------------|---------------------------------------------------|-----------------------------------------------|
| mode, targetLang, annotateLevel        | both: `storage.local.settings` and `config.prefs` | newest `updatedAt` wins, exchanged on `ping` and `set-prefs` |
| fontScale, bottomOffset, mergedMode, enabled | extension `storage.local.settings`          | —                                             |
| subtitle styles                        | app → `config.styles`                             | delivered in every `ping` reply               |
| engine, cloud provider/model/base URL  | `config.json` (written by the app only)           | read fresh by `Translator` on every request   |
| cloud consent per provider (custom: per base URL) | `config.cloudConsent` (the app's alert only) | read fresh by `Translator` on every request |
| API keys                               | shared keychain, entered in the app only          | —                                             |
| local models                           | app download → `models/models--<org>--<name>/` (plus `.download-tmp/<org>--<name>/` until it's complete, §3) | read from disk by `Translator` in both processes |
| translation / annotation caches        | extension `storage.local` (`ms:` keys)            | index mirrored to the app on `ping`           |
| vocabulary word lists                  | app → `vocab/<movieId>.json`                      | —                                             |
| transcript waiting to be organized     | appex `save-transcript` → `vocab-pending/<movieId>.json` | read by the app; deleted once its words are saved |
| where 整理本集單字 stands per episode   | `vocab-status/<movieId>.json`: appex writes the first `queued`, the app everything after | read back by `vocab-status` (§5.3) |

`config.json` is written by two processes, so every write goes through
`MultiSubConfig.update { … }` (load fresh → mutate → atomic write). The app's
`ConfigStore` reloads when it becomes active.

## 5. Messages

### 5.1 content.js ↔ background.js (`runtime.Port` named `multisub`)

A job is keyed by kind, movie, target language and source track language.
A tab that sends the same input as a running job joins it: it gets a replay of
what is done so far, then the same `progress` and `done`. Different input for
the same key replaces the running job, and that job's tabs get `superseded`
(they ask again later and replay what the new job cached). A new job from a
tab (another mode, language or episode) makes that tab leave its previous
job, and a job is cancelled when its last tab leaves or disconnects, so a
late `progress` can never land in the wrong episode or mode and a closed tab
stops spending cloud calls. The glossary pass stops with its job. Safari unloads the background page 30 s after the last event and
does not count pending native calls, so while a job runs content.js posts
`keepalive` every 15 s and background.js posts `heartbeat` whenever it has
been quiet for 15 s.

content → background

| type            | fields                                                                                           |
|-----------------|--------------------------------------------------------------------------------------------------|
| `job`           | `kind: "translate" \| "annotate"`, `movieId`, `sourceLang`, `targetLang`, `lines[]`, `referenceLines[]` (string\|null), `starts[]` (cue start seconds), `startIndex`, `level` (annotate) |
| `prioritize`    | `kind`, `movieId`, `index` — the user seeked; move the chunks at/after `index` to the front     |
| `line`          | `kind`, `text`, `targetLang`, `level`, `sourceLang?` — DOM fallback, one line at a time. On the local engine (or while it's unknown) background.js sends one line to native at a time and keeps only each tab's newest waiting line |
| `episode-title` | `movieId`, `sourceLang`, `targetLang`, `seriesTitle`, `episodeTitle`, `seasonNumber`             |
| `keepalive`     | — (only keeps the background page loaded)                                                        |

background → content

| type          | fields                                                                                  |
|---------------|-----------------------------------------------------------------------------------------|
| `progress`    | `kind`, `start`, `items[]` — translations (string) or annotations (`[{term, gloss}]`)   |
| `done`        | `kind`, `fromCache?`, and for a job that skipped chunks `partial: true`, `missing` (lines still null), `code` (last chunk error) |
| `superseded`  | `kind` — a job with different input for the same key replaced this tab's job            |
| `error`       | `kind`, `code`, `detail`                                                                |
| `line-result` | `kind`, `text`, and `result`, `code` or `dropped: true` (a newer line from this tab replaced it while waiting) |
| `heartbeat`   | — (only keeps the background page loaded)                                               |

The popup also sends `engine-changed` to the Netflix tabs when a `ping`
shows that an engine became ready since its last answer (set up in the app
meanwhile), so a job that failed with `engine-not-ready` retries immediately.
A chunk that fails with `rate-limited`, `network` or `provider-error` is
retried twice (2 s, 6 s). If it still fails, only that chunk is skipped: its
lines stay null in memory and in the cache, and the workers move on. The whole
job fails (`error`) on `auth-failed`, `engine-not-ready`, `model-not-ready`
or `native-unavailable`, after 3 chunk failures in a row,
or when no line at all came back. A job that skipped chunks ends with
`done {partial: true}`; content.js shows a short notice and retries it
quietly, and the retry redoes only the missing lines. A failed job is retried
by content.js after 30 s; failed and partial jobs share the limit of 5 retries
per episode (reset by a complete `done`). A line the provider refused also stays null, but doesn't make
the job partial: asking again right away would most likely be refused again.

Error codes shown to the user: `native-unavailable`, `engine-not-ready`,
`model-not-ready`, `auth-failed`, `rate-limited`, `network`, `provider-error`.
(A cloud provider without consent is `engine-not-ready`.)

### 5.2 background.js → native (`runtime.sendNativeMessage`)

| action             | request                                                                 | reply (`ok: true` …)                                   |
|--------------------|-------------------------------------------------------------------------|--------------------------------------------------------|
| `ping`             | `cacheIndex[]`                                                          | `styles`, `prefs`, `engine` (below), `modelId`, `modelDownloaded`, `modelLoaded`, `cacheDeleteRequest?` |
| `translate`        | `lines[]`, `targetLang`, `reference[]?`, `glossary{}?`                  | `translations[]`                                       |
| `extract-glossary` | `pairs[{source, reference}]`, `targetLang`                              | `glossary{}`                                           |
| `annotate`         | `lines[]`, `context[]`, `reference[]`, `sourceLang`, `targetLang`, `level` | `annotations[[{term, gloss}]]`                      |
| `set-prefs`        | `prefs{mode, targetLang, annotateLevel, updatedAt}`                     | —                                                      |
| `unload`, `open-app` | unchanged                                                             |                                                        |
| `save-transcript`  | `movieId`, `seriesTitle`, `episodeTitle?`, `seasonNumber?`, `sourceLang`, `targetLang`, `lines[]` | — (stages the transcript, marks the episode handed off; §5.3) |
| `vocab-status`     | `movieId`                                                               | `movieId`, `state` (below; `none` when nothing recent), `accepted`, `done`, `total`, `wordCount?`, `code?`, `message?`, `title?`, `updatedAt` (ms) |

Any other action gets `unknown-action`. None of them sets up the AI engine
(§3): background.js and the popup read it from `ping`, and the popup opens
the app to set one up.

`engine` (as returned by `ping`):
`{ configured: "auto"|"local"|"cloud", active: "local"|"cloud"|null, provider, providerName, model, hasKey, localModelId, localModelDownloaded, localModelLoaded }`.
`active` is null (or `"local"` under `auto`) while the selected cloud
provider has a key but no recorded consent.

`engine.baseURL` is present only for the custom provider. Optional fields
with no value (`active`, `prefs`) are omitted rather than sent as
null.

Errors are `{ ok: false, error: <code>, detail?: <message> }`. Besides the
codes above, unexpected failures (including a request cancelled while it
waited for the local model to load) come back as `<action>-failed`, and a
malformed request as `bad-request`. background.js folds `<action>-failed` and `bad-request` from
job requests into `provider-error`, which it retries.

The host app opens on `multisub://<destination>` URLs sent through
`open-app`: `welcome`, `general`, `engine` (local-model setup), `styles`,
`vocab` (just the tab), `vocab?movieId=…` (organize that episode, §5.3).
On every URL the app asks macOS to bring it forward (`NSApp.activate()`),
but a URL opened from the Safari extension's process usually leaves it
behind Safari (cooperative activation), so nothing may depend on the user
seeing the app's window.

### 5.3 Vocabulary hand-off (整理本集單字)

Pressing 「整理本集單字」 in the popup is the user's consent; the app starts
without asking again.

1. popup.js → content.js `organize-vocab` (no reply until the hand-off is
   done). content.js checks that the active track is English and collects
   the episode's cue text and titles.
2. content.js → background.js `organize-vocab {payload}` → native
   `save-transcript`. The appex stages the transcript in `vocab-pending/`
   and writes `vocab-status/<movieId>.json` as `queued` with
   `accepted: false` ("handed off"), unless a queued or running entry for
   that episode is still fresh (the app ignores the repeat and keeps going).
   It also unloads its own local model when idle, since the app is about to
   load one. If the save fails, nothing is opened.
3. background.js → native `open-app {destination: "vocab", movieId}` opens
   `multisub://vocab?movieId=…`. `AppRouter` switches to 生詞本 and calls
   `VocabExtractionManager.request(movieId:)`, which lives at the app root,
   so it works whether the window is open, on another tab, or closed; on a
   cold launch the URL goes through `AppDelegate.pendingOpenURL`, and the
   manager also picks up a fresh unaccepted hand-off it finds at launch.
4. The manager checks the gates (English source; an engine
   `Translator.resolveEngine` can run) and queues the episode. Jobs run one
   at a time. A job already queued or running for that episode keeps going;
   a failed one runs again. A gate failure is a failed job, not an alert.
5. While anything is queued or running the manager rewrites each active
   entry at least every 30 s (heartbeat), holds a `.userInitiated`
   process activity so App Nap doesn't throttle the app behind Safari, and
   keeps the app running if the last window closes (it quits once the queue
   is empty, if no window was reopened).

`vocab-status/<movieId>.json` (`VocabOrganizeStatus`):

| state     | meaning                                         | extra fields                                |
|-----------|-------------------------------------------------|---------------------------------------------|
| `queued`  | handed off (`accepted: false`) or waiting for another episode | —                             |
| `running` | extracting                                      | `done` / `total` segments of ~40 lines (`Translator.vocabSegmentCount`) |
| `done`    | words saved to `vocab/`                         | `wordCount`                                 |
| `failed`  | stopped; the transcript stays staged for 「重試」 | `code`, `message` (zh-TW, worded for the app) |

Failure codes: `non-english`, `engine-not-ready`, `model-not-ready`, the
provider codes (`auth-failed`, `rate-limited`, `network`,
`provider-error`), `vocab-empty` (no words at all, almost always every
request failed), `vocab-failed` (anything else), and two that readers
derive from a queued/running entry not refreshed for 2 minutes:
`vocab-interrupted` (the app had accepted it) and `vocab-not-started` (it
never did). At launch the app turns such leftovers into failed jobs with
「重試」, deletes done/failed entries older than 24 hours (and a failed
one's staged transcript), and deletes staged transcripts no entry points at
that are older than 24 hours. `vocab-status` reports done/failed entries
older than 24 hours as `none`.

The popup asks `vocab-status` once for the episode in the tab, then every
2 s (its tab poll) while the state is `queued` or running, and shows it
under the button: 「已交給 MultiSub App…」, 「整理中（3/12）」, 「整理好了：48
個單字」 with 「打開生詞本」 (`open-app {destination: "vocab"}`; the text also
says where to look, since this may not bring the app forward either), or
the failure text `organizeVocabErrorText` maps from `code` (the app's
`message` for an unknown code). The button is disabled while the episode is
queued or running; pressing it again after a failure is the retry.

In the app, 生詞本 lists the manager's jobs above the episodes (spinner and
「整理中（3/12）」, or the reason and 「重試」 for a failed one); selecting
one shows a progress view. The sidebar's 生詞本 item shows an activity
indicator while anything is queued or running. When words are saved the
manager publishes a `focus` the view applies on appear or right away:
reload and select the new episode (unless the user has moved on to
another row).

## 6. Reliability measures for loading subtitles

* `inject.js` is declared as a `world: "MAIN"` content script at
  `document_start`, so its hooks are in place before Netflix's player boots;
  the `<script>` tag injection from `content.js` remains as a fallback and is
  de-duplicated by a page-world flag. `inject.js` refuses to run in the
  isolated world.
* Manifests are captured from both `JSON.parse` and `Response.prototype.json`.
* A failed primary-track download is retried after 2 s and 6 s before falling
  back to DOM text. `inject.js` then forgets the track list it posted for that
  movie, so Netflix's next manifest (with fresh URLs) is posted again and
  content.js gets two more tries at the full track from the fallback.
* The content script pings native at startup (not only after 60 s), so styles
  and preferences apply immediately.
* The popup detects (a) a Netflix tab without the content script (extension
  enabled after the page loaded) and offers a one-click reload, and (b) missing
  website access and offers to request it.
* Background jobs start at the current playback position and re-prioritise on
  seeks, so subtitles appear where the viewer is instead of from episode start.
* When Safari reloads the extension (an update, or the extension turned off
  and on) it injects the content scripts into open tabs again, next to the
  old `content.js`, which keeps running. The newest instance owns the page:
  instances announce themselves (`window.postMessage`,
  `{__multisub_instance: true, type: "hello", id, startedAt, managesNative}`)
  and an instance that hears a newer one tears itself down. Each instance
  tags what it attaches with `data-ms-instance` and keeps a style rule that
  hides every other `#multisub-*` element, which is what holds against
  versions that don't announce themselves. An instance whose extension
  context is gone (`runtime.id` cleared, or overlay.css's
  `--multisub-stylesheet` marker removed, which is how WebKit shows it) tears
  itself down and shows Netflix's own subtitles again.
* `inject.js` runs once per page, so after such a reload the new `content.js`
  talks to the `inject.js` the page loaded with. Their messages are a
  protocol between versions: nothing is renamed or removed, and new fields
  are optional (`cues` messages carry `cleaned: true` since both parsers
  share one text cleanup; `content.js` cleans cues without it). The rule is
  written at the top of `inject.js`.

## 7. Build configuration

* `MultiSub/MultiSub.xcconfig` (tracked) defines `MULTISUB_BUNDLE_ID`,
  `ARCHS = arm64` and the distribution switch; `Local.xcconfig` (gitignored,
  optional) sets `DEVELOPMENT_TEAM` and your own bundle ID.
* App Group: `$(TeamIdentifierPrefix)$(MULTISUB_BUNDLE_ID)` — no portal
  registration needed on macOS.
* `MULTISUB_DISTRIBUTION = direct | appstore`. `appstore` adds the `APP_STORE`
  Swift condition (compiles out the GitHub update checker/downloader) and uses
  `MultiSub-AppStore.entitlements`. `scripts/archive-appstore.sh` sets it.
* No Swift macros: `Shared/HubBridges.swift` replaces mlx-swift-lm's
  MLXHuggingFace macros, so a fresh clone builds without "Trust & Enable".
* `mlx-swift-lm` is pinned to the 3.32.x release line (it used to track `main`,
  which broke builds whenever packages were re-resolved).

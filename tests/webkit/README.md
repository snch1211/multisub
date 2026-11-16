# WebKit tests

These tests run the MultiSub extension in WebKit, the engine Safari uses,
without driving Safari. A small Swift tool (`harness`) loads `extension/`
through WebKit's public `WKWebExtensionController` API (macOS 15.4 and later),
which runs the background page, the popup and the content scripts in web views
the tool owns. Native messages never reach the real app: WebKit only routes
`runtime.sendNativeMessage` to an app extension inside Safari, so the harness
answers them with a stub.

## Running

```sh
tests/run.sh                      # every extension test; builds the harness first on macOS
node tests/webkit/webkit.test.js  # just these
tests/webkit/build.sh             # just build tests/webkit/.build/harness
```

`webkit.test.js` builds the harness if needed and skips (exit 0, with a
message) when not on macOS or when the build fails. It takes about a minute.
Snapshots of the watch scenarios land in `tests/webkit/.build/snapshots/`.

The popup scenarios in `tests/extension/popup.test.js` run in WebKit too once
the harness is built (`tests/extension/popup/runner.js`). Set
`MULTISUB_POPUP_ENGINE=chrome` to run them in headless Google Chrome instead,
or `webkit` to insist on WebKit.

Running the harness by hand:

```sh
H=tests/webkit/.build/harness
$H smoke extension --lang zh-Hant
$H watch extension tests/webkit/fixtures/scenarios/translate.json --snapshot /tmp/translate.png
$H watch extension tests/webkit/fixtures/scenarios/netflix.json --scheme http --verbose
$H page /path/to/page.html
```

Progress goes to stderr. `smoke` and `watch` end with one line on stdout,
`RESULT {...json...}`, listing every check. Exit status: 0 passed, 1 a check
failed, 2 usage or setup error, 3 timed out.

## What it covers

`smoke <extDir>` loads the extension, its background content and
`popup.html`, then sends `ping-native` from the popup through the background
page to the native stub. It fails on extension or context errors, on a popup
or background page not decoded as UTF-8, and when the ping doesn't come back
`ok`. `--lang` runs it as if the Mac were set up in another language
(`zh-Hant`, `ja`, `en`, `zh-Hans`, `ko`), which changes the legacy encoding
WebKit falls back to (Big5, Shift_JIS, windows-1252, GBK, EUC-KR).
`webkit.test.js` runs it in zh-Hant, ja and en, and checks that a copy of the
extension with the old `"background": {"scripts": [...]}` manifest and the
old `shared.js` (curly apostrophes written as they are in a regular
expression) fails in zh-Hant: WebKit then generates the background page
without a charset, `shared.js` is decoded as Big5 and stops parsing, and the
ping comes back as `native-unavailable` with "shared.js did not load". With
today's `shared.js`, whose regular expressions write non-ASCII characters as
`\u` escapes, the same manifest still gives a page that isn't UTF-8, but
the ping gets through. `tests/extension/layout.test.js` checks the escapes'
effect without WebKit: every script the background page and the popup load
must parse when decoded as Big5, GBK or Shift_JIS.

`page <file.html>` loads a local page in a plain `WKWebView` and prints what
the page writes between `@@OUT@@` and `@@END@@`. The popup runner uses it.

`watch <extDir> <scenario.json>` is an end-to-end run of the content scripts
on a mock Netflix watch page (`fixtures/netflix-watch.html`):

- The scenario's settings go into `storage.local` before the page loads.
- The page is served at `https://www.netflix.com/watch/80000001` in a tab of
  the extension controller, so WebKit injects `shared.js`, `content.js` and
  `inject.js` (in the page's main world) as Safari would. The harness checks
  that `inject.js` hooked `JSON.parse` before the page's own scripts ran,
  which only the `world: "MAIN"` content script does: `content.js`'s
  `<script src>` fallback also runs `inject.js`, but after the page.
- The mock player fetches a Netflix-style manifest (`fixtures/manifest.json`)
  with `Response.json()` (or `JSON.parse`, `"manifestVia": "parse"`) after
  building the request with `JSON.stringify`, so both of `inject.js`'s hooks
  take part. The harness checks that the request asked for the WebVTT profile.
- English comes as WebVTT with `&lrm;`, a double-encoded `&amp;lrm;`, an
  uppercase `&AMP;LRM;`, `<c>` tags and a two-line cue; Traditional Chinese
  comes as TTML (DFXP) with the marks as Netflix writes them there
  (`&amp;lrm;`, `&#8206;`), next to a forced-narrative track that must not be
  picked. The manifest lists the forced track first on purpose: a second-line
  choice that took the first zh-Hant track would pick it.
- A 30-second silent video made with ffmpeg (once, kept in `.build/`) is
  seeked to each checkpoint's time. Without ffmpeg, or with `--video none`,
  `currentTime` is set on a video with no media, which WebKit keeps and
  reports back.
- The native stub answers `translate` with `"[zh] " + line` and `annotate`
  with the first word longer than six letters as the term and
  `"zh:" + lowercased word` as the gloss, in the reply shapes of
  `SafariWebExtensionHandler.swift`. `"nativeErrors"` in a scenario makes it
  answer an action with an error code instead. Every run checks that no
  direction mark or entity reached it in subtitle text (lines, context,
  reference lines, glossary pairs): that text goes into the AI prompts.
- At every checkpoint the harness reads `#multisub-original`,
  `#multisub-text`, the `.ms-term`/`.ms-gloss` pairs, the hint and
  `#multisub-text`'s computed font size relative to a single line
  (`textScale`: 0.8 under the original, 1 alone in annotate mode), and checks
  that no HTML entity such as `&lrm;` shows as text anywhere on the page.
- At the end it opens the popup, which finds the tab with `tabs.query` and
  asks `content.js` for its status with `tabs.sendMessage`; the scenario can
  check that status and how often each native action was called.
- A checkpoint can first reload the extension under the open tab
  (`"action": "reload-extension"`: the context is unloaded and a new one
  for the same extension, optionally another build of it, is loaded) or
  turn it off (`"unload-extension"`). The overlay is then read from the
  first visible `#multisub-overlay`, and `overlays` / `overlaysInDOM`
  count them.

The scenarios in `fixtures/scenarios/` cover the netflix, translate and
annotate modes, translate with an engine that isn't set up (the hint text
comes from `shared.js`), and the extension reloaded and then turned off under
an open tab (`reload.json`). `webkit.test.js` runs each of them, runs the
engine-error one again in ja to check that the content scripts' Chinese text
survives a Shift_JIS default, runs translate with `--scheme http`, where the
page is served over http and the fixtures come from a loopback HTTP server
with CORS headers and byte ranges, and runs translate again with
`"manifestVia": "parse"` so `inject.js`'s `JSON.parse` hook is the one that
captures the manifest. It also checks that copies of the extension with a
known mistake fail:

- `inject.js` doesn't clean cue text: `&lrm;` on screen;
- `inject.js` doesn't clean TTML cues: `&lrm;` and U+200E on the second
  line in netflix mode, and in the reference lines sent to the stub;
- `content.js` doesn't skip forced tracks for the second line: the forced
  track's one cue at 18 s instead of the full track's line;
- `inject.js` is no longer a `world: "MAIN"` content script: the overlay
  still works through the fallback, but the `JSON.parse` hook comes too late.
- `content.js` doesn't announce itself: after a reload the old instance
  keeps its overlay on the page;
- `overlay.css` has no `--multisub-stylesheet` marker: a turned-off
  extension's content script keeps drawing and keeps Netflix's own
  subtitles hidden.

`reload.json` also runs over a copy of the extension whose `content.js`
neither steps aside nor marks its elements, as the versions already shipped
do: after the reload its overlay stays in the page but must be hidden.

### Reloading the extension under an open tab

This is what WebKit does, and what the reload scenarios rely on:

- Loading a context injects its content scripts (and stylesheets) into the
  tabs already open, next to whatever is running there. Unloading one
  removes its stylesheets from the page but not its scripts: the old
  `content.js` keeps its timers and keeps drawing, until the tab is
  reloaded.
- In such a stale content script `browser.runtime.id`,
  `runtime.getURL()` and `runtime.getManifest()` keep working and
  `runtime.connect()` doesn't throw, while `storage.local` calls never
  settle. That is why `content.js` tells a dead context by its stylesheet
  (overlay.css's `--multisub-stylesheet` marker) rather than by `runtime.id`
  alone.
- The harness gives the new context the old one's `uniqueIdentifier` and
  `baseURL`, as Safari keeps an extension's identity across updates, so
  `storage.local` carries over.
- Timers in the tab may fire only once a second (seen in the content script
  loaded by a reload; the web view is never on screen), so `content.js`
  checks the stylesheet by elapsed time, not by a count of ticks.

The scenario format is described at the top of `harness/Watch.swift`.

## What it can't cover

- Real Netflix: its player, its DRM-protected playback, the markup and
  manifest format it uses today, timing on a real network. The mock page
  models only what `inject.js` and `content.js` read.
- The real app. Only Safari can start the app extension
  (`SafariWebExtensionHandler`), so the engine, the API keys, the local
  model and the shared settings are all stubbed.
- Safari itself: its extension settings and permission prompts, how it caches
  an installed extension between updates, when it unloads a non-persistent
  background page (Safari stops it 30 s after the last event; here it keeps
  running), and the toolbar popup's presentation.
- The background page checks (`decoded as UTF-8`, `sees shared.js`) read the
  background page through WebKit's `_backgroundWebView` SPI. If a WebKit
  update removes it, those two checks are skipped and the ping round trip
  remains.

## WebKit details the harness depends on

- A resource base URL that still contains `..` makes WebKit kill the process
  (SIGKILL, no message). Every path from the command line is resolved first.
- Content scripts are only injected into web views that use the controller's
  own data store (`controller.configuration.defaultWebsiteDataStore`); a web
  view with any other store, even another non-persistent one, silently gets
  none.
- An https page can't load anything over http, loopback included (mixed
  content). That is why `--scheme https` (the default) inlines the fixtures
  as `data:` URLs and `--scheme http` uses the loopback server.
- WebKit's legacy default encoding follows `__CF_USER_TEXT_ENCODING` (set at
  login from the Mac's primary language), not `AppleLanguages`. `--lang`, or
  `-AppleLanguages "(ja)"` on the command line, sets both and relaunches the
  harness.
- The tab web views sit in a borderless window that is never shown, with
  `inactiveSchedulingPolicy = .none`, so timers, media and snapshots work as
  in a visible tab. The harness doesn't open Safari, doesn't touch
  `/Applications`, and keeps all its data in non-persistent stores.

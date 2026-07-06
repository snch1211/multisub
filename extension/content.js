// Content script (isolated world) for netflix.com.
//
// Responsibilities:
//  - Inject inject.js into the page world to capture subtitle tracks.
//  - Pick a source track, request its cues, and ask the background script
//    to translate the whole episode (pre-translation + cache).
//  - Render the translated second subtitle in an overlay synced to
//    video.currentTime, with user-configurable size/position.
//  - DOM-observer fallback: if track capture fails, translate whatever
//    subtitle text Netflix renders, line by line.
(() => {
  'use strict';
  const api = typeof browser !== 'undefined' ? browser : chrome;

  // Debug logging for A3 interception diagnosis. Set to false once resolved.
  const DEBUG = false;
  function dbg() {
    if (!DEBUG) return;
    try { console.log.apply(console, ['[MultiSub][content]'].concat([].slice.call(arguments))); } catch (e) { /* ignore */ }
  }

  // D1: overlay subtitle style, single source of truth = App's config.json
  // (MultiSubConfig.styles). Defaults mirror the pre-D1 hardcoded overlay.css
  // values so upgrading doesn't change the look before the App has ever set
  // anything. Kept in sync with SubtitleStyle in TranslatorCore.swift.
  const DEFAULT_STYLES = {
    textColor: '#ffffff',
    backgroundColor: '#000000',
    backgroundOpacity: 0.5,
    outlineEnabled: true,
    outlineColor: '#000000',
    fontFamily: '"Netflix Sans", "Helvetica Neue", "PingFang TC", "Noto Sans TC", sans-serif',
    lineHeight: 1.35,
    boldEnabled: false
  };

  const DEFAULT_SETTINGS = {
    enabled: true,
    targetLang: 'zh-TW',
    fontScale: 1.0,
    bottomOffset: 10, // percent from bottom of the player
    styles: DEFAULT_STYLES,
    mergedMode: false // D3: hide Netflix's native subtitle, show original+translation in our own overlay
  };

  // D2: must match popup.html's #bottomOffset slider min/max.
  const DRAG_MIN_OFFSET = 0;
  const DRAG_MAX_OFFSET = 40;

  function hexToRgba(hex, opacity) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
    if (!m) return 'rgba(0, 0, 0, ' + opacity + ')';
    const n = parseInt(m[1], 16);
    const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
    return 'rgba(' + r + ', ' + g + ', ' + b + ', ' + opacity + ')';
  }

  // D1: approximates overlay.css's outline as a 4-direction text-shadow
  // (no reliable cross-engine text-stroke), toggled off entirely via 'none'.
  function outlineShadow(enabled, color) {
    if (!enabled) return 'none';
    return [
      '-1px -1px 0 ' + color,
      '1px -1px 0 ' + color,
      '-1px 1px 0 ' + color,
      '1px 1px 0 ' + color
    ].join(', ');
  }

  // D1: merges a `styles` object from a native `ping` response into
  // storage.local.settings if it differs, which content.js's own
  // storage.onChanged listener (below) then applies via applySettingsToOverlay().
  function mergeStylesFromNative(res) {
    if (!res || !res.ok || !res.styles) return;
    if (JSON.stringify(res.styles) === JSON.stringify(settings.styles)) return;
    const next = Object.assign({}, settings, { styles: res.styles });
    api.storage.local.set({ settings: next }).catch(() => {});
  }

  let settings = Object.assign({}, DEFAULT_SETTINGS);

  const state = {
    urlMovieId: null,
    tracks: [],
    activeTrackId: null,
    sourceMode: 'auto', // 'auto' (follow Netflix's player selection) | 'manual' (user picked in popup)
    netflixActiveBcp47: null, // last bcp47 reported by inject.js's active-track detector, or null if unknown/off
    cues: [],
    referenceTrackId: null,
    referenceCues: null, // null = not yet resolved; [] = resolved, no official target-lang track
    referenceLines: null, // aligned to `cues`, same length, String|null per entry
    referencePollTimer: null,
    translations: [],
    status: 'idle', // idle | waiting-tracks | fetching | translating | done | fallback | error
    errorHint: '',
    translatedCount: 0,
    port: null,
    lastRenderedKey: null,
    trackPollTimer: null,
    // DOM fallback
    fallback: false,
    fallbackCache: new Map(), // original text -> translation
    fallbackInflight: new Set(),
    fallbackCurrentText: '',
    // D2: drag-to-position mode. Lives only here (not storage.local) so it
    // doesn't linger enabled across page reloads; popup reads it back via
    // get-status's dragMode field.
    dragModeEnabled: false,
    // 2026-07-07: movieId -> [resolver, ...] for in-flight 'get-title'/
    // 'title' round trips with inject.js (see requestEpisodeTitle). Must
    // support more than one concurrent waiter per movieId: this was
    // previously a single `{movieId, resolve}` slot, which broke when two
    // lookups for the same episode overlapped — `startEpisodeTranslation()`
    // fires one automatically for the cache-management title, and clicking
    // "整理本集單字" while that's still in flight fires a second one before
    // the first resolves. The second call overwrote the slot, so the first
    // caller's request got silently orphaned (found via real usage: the
    // cache entry's title ended up wrong — falling through to
    // `document.title` after its own 1.5s timeout — specifically when the
    // vocab button was clicked mid-translation).
    pendingTitleRequests: new Map()
  };

  // ---------------------------------------------------------------------------
  // Inject the page-world script as early as possible.
  // ---------------------------------------------------------------------------
  function injectPageScript() {
    const s = document.createElement('script');
    s.src = api.runtime.getURL('inject.js');
    s.onload = () => s.remove();
    (document.head || document.documentElement).appendChild(s);
  }
  injectPageScript();

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------
  api.storage.local.get('settings').then((res) => {
    if (res && res.settings) settings = Object.assign({}, DEFAULT_SETTINGS, res.settings);
    applySettingsToOverlay();
  }).catch(() => {});

  api.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !changes.settings) return;
    const before = settings.targetLang;
    const wasEnabled = settings.enabled;
    settings = Object.assign({}, DEFAULT_SETTINGS, changes.settings.newValue || {});
    applySettingsToOverlay();
    if (settings.targetLang !== before) {
      // Target language changed: the reference track (T2) depends on
      // targetLang too, so re-resolve it before retranslating.
      state.fallbackCache.clear();
      if (state.cues.length) beginTranslationPipeline();
    } else if (settings.enabled && !wasEnabled && state.cues.length && state.status !== 'done') {
      // M1: background.js paused the episode loop (and unloaded the model)
      // while we were off — resume it now. Already-translated lines replay
      // instantly from background.js's cache; only the remaining batches
      // re-run and lazily reload the model.
      beginTranslationPipeline();
    }
  });

  // ---------------------------------------------------------------------------
  // Messages from the page-world script.
  // ---------------------------------------------------------------------------
  window.addEventListener('message', (ev) => {
    if (ev.source !== window) return;
    const msg = ev.data;
    if (!msg || msg.__multisub !== true) return;

    if (msg.type === 'tracks') {
      dbg('recv tracks for movieId', msg.movieId, '(url=', state.urlMovieId, ') count=',
          msg.tracks && msg.tracks.length, msg.tracks);
      if (!state.urlMovieId || msg.movieId !== state.urlMovieId) return; // prefetch of another episode
      state.tracks = msg.tracks;
      if (state.trackPollTimer) { clearInterval(state.trackPollTimer); state.trackPollTimer = null; }
      let track = null;
      if (state.sourceMode === 'auto' && state.netflixActiveBcp47) {
        track = findTrackByBcp47(msg.tracks, state.netflixActiveBcp47);
      }
      if (!track) track = chooseTrack(msg.tracks);
      dbg('chosen track:', track);
      if (track) {
        switchToTrack(track.id);
      } else {
        enableFallback('no-suitable-track');
      }
    } else if (msg.type === 'cues') {
      if (msg.movieId !== state.urlMovieId) return;
      if (msg.purpose === 'reference') {
        if (msg.trackId !== state.referenceTrackId) return; // stale, superseded by a newer track switch
        if (state.referencePollTimer) { clearTimeout(state.referencePollTimer); state.referencePollTimer = null; }
        state.referenceCues = msg.cues || [];
        dbg('reference: cues received, count=', state.referenceCues.length);
        startEpisodeTranslation();
        return;
      }
      dbg('recv cues for movieId', msg.movieId, 'count=', msg.cues && msg.cues.length,
          'sample=', msg.cues && msg.cues.slice(0, 2));
      state.cues = msg.cues || [];
      if (state.cues.length) {
        state.fallback = false;
        beginTranslationPipeline();
      } else {
        enableFallback('empty-track');
      }
    } else if (msg.type === 'track-error') {
      if (msg.movieId !== state.urlMovieId) return;
      if (msg.purpose === 'reference') {
        if (msg.trackId !== state.referenceTrackId) return;
        if (state.referencePollTimer) { clearTimeout(state.referencePollTimer); state.referencePollTimer = null; }
        dbg('reference: fetch failed, proceeding without reference:', msg.error);
        state.referenceCues = [];
        startEpisodeTranslation();
        return;
      }
      enableFallback(msg.error);
    } else if (msg.type === 'active-track') {
      if (msg.movieId !== state.urlMovieId) return;
      dbg('recv active-track', msg.bcp47, msg.displayName, 'sourceMode=', state.sourceMode);
      state.netflixActiveBcp47 = msg.bcp47;
      if (state.sourceMode !== 'auto') return; // user overrode via popup; don't fight them
      if (!msg.bcp47) {
        // Netflix subtitles turned off in the player UI: keep showing the last
        // followed track rather than clearing it (decision recorded in PLAN.md T1).
        dbg('active-track: Netflix subtitles off, keeping last track');
        return;
      }
      if (!state.tracks.length) return; // manifest not captured yet; 'tracks' handler will match once it arrives
      const match = findTrackByBcp47(state.tracks, msg.bcp47);
      if (match && match.id !== state.activeTrackId) {
        dbg('active-track: switching to', match.id, match.language);
        switchToTrack(match.id);
      }
    } else if (msg.type === 'title') {
      const waiters = state.pendingTitleRequests.get(msg.movieId);
      if (waiters) {
        state.pendingTitleRequests.delete(msg.movieId);
        const info = {
          seriesTitle: msg.seriesTitle || null,
          episodeTitle: msg.episodeTitle || null,
          seasonNumber: typeof msg.seasonNumber === 'number' ? msg.seasonNumber : null,
          episodeNumber: typeof msg.episodeNumber === 'number' ? msg.episodeNumber : null
        };
        // Every concurrent caller waiting on this same movieId gets the same
        // answer — see `pendingTitleRequests`' doc comment for why this must
        // support more than one waiter.
        for (const waiter of waiters) waiter(info);
      }
    }
  });

  function pageCommand(msg) {
    window.postMessage(Object.assign({ __multisub_cmd: true }, msg), '*');
  }

  // Among a set of same-ish candidates, prefer non-forced, then full
  // subtitle tracks over closed-captions. Forced (narrative-only) tracks
  // carry just a handful of cues (foreign-dialogue burn-ins), so picking one
  // by language match alone would leave the overlay empty almost the whole
  // episode.
  function preferredTrack(candidates) {
    if (!candidates.length) return null;
    const nonForced = candidates.filter((t) => !t.forced);
    const pool = nonForced.length ? nonForced : candidates;
    const subs = pool.filter((t) => /subtitle/i.test(t.trackType));
    const cc = pool.filter((t) => /closed/i.test(t.trackType));
    return subs[0] || cc[0] || pool[0];
  }

  function chooseTrack(tracks) {
    if (state.activeTrackId) {
      const kept = tracks.find((t) => t.id === state.activeTrackId);
      if (kept) return kept;
    }
    return preferredTrack(tracks) || tracks[0] || null;
  }

  // Normalize a BCP-47 language code for matching Netflix's active-track
  // report against the captured track list's `language` field. Netflix uses
  // zh-Hant/zh-Hans (script subtags) for Chinese; everything else compares
  // on the primary language subtag.
  function normalizeBcp47(code) {
    if (!code) return '';
    const c = String(code).toLowerCase();
    if (c.indexOf('zh') === 0) {
      if (/hant|-tw|-hk|-mo/.test(c)) return 'zh-hant';
      if (/hans|-cn|-sg/.test(c)) return 'zh-hans';
      return 'zh';
    }
    return c.split('-')[0];
  }

  function findTrackByBcp47(tracks, bcp47) {
    if (!bcp47) return null;
    const norm = normalizeBcp47(bcp47);
    const matches = tracks.filter((t) => normalizeBcp47(t.language) === norm);
    return preferredTrack(matches);
  }

  // T2: find the official target-language track to use as a translation
  // reference (for name/terminology consistency, wired up in T3). Forced and
  // CC tracks are excluded per PLAN.md T4 — they're not representative full
  // dialogue. Never returns the source track itself.
  function findReferenceTrack(tracks, targetLang, sourceTrackId) {
    const norm = normalizeBcp47(targetLang);
    if (!norm) return null;
    const matches = tracks.filter((t) =>
      t.id !== sourceTrackId && !t.forced && !/closed/i.test(t.trackType) &&
      normalizeBcp47(t.language) === norm);
    return matches[0] || null;
  }

  // T2: align source cues to reference-track cues by time overlap (IoU on
  // the [start,end] interval). One-to-many / many-to-one overlaps are
  // merged in chronological order; source cues with no overlapping
  // reference cue get `null`. Pure function — sourceCues/refCues are plain
  // [{start,end,text}] arrays sorted by start (as produced by the WebVTT/TTML
  // parsers), so this is easy to hand-test by pasting sample arrays into a
  // console.
  function alignReferenceCues(sourceCues, refCues) {
    const result = new Array(sourceCues.length).fill(null);
    if (!refCues || !refCues.length) return result;
    let refIdx = 0;
    for (let i = 0; i < sourceCues.length; i++) {
      const src = sourceCues[i];
      // Advance past reference cues that end before this source cue starts,
      // but keep any that might still overlap a later source cue too.
      while (refIdx < refCues.length - 1 && refCues[refIdx].end < src.start) refIdx++;
      const matched = [];
      for (let j = refIdx; j < refCues.length; j++) {
        const ref = refCues[j];
        if (ref.start > src.end) break;
        const overlap = Math.min(src.end, ref.end) - Math.max(src.start, ref.start);
        if (overlap > 0) matched.push(ref.text);
      }
      if (matched.length) result[i] = matched.join(' ');
    }
    return result;
  }

  // Pick up to n roughly evenly-spaced indices from [0, length) for DEBUG
  // sampling (T2 acceptance criterion: eyeball ~10 pairs for drift).
  function pickSampleIndices(length, n) {
    if (length <= n) return Array.from({ length: length }, (_, i) => i);
    const out = [];
    for (let i = 0; i < n; i++) out.push(Math.floor(i * length / n));
    return out;
  }

  function switchToTrack(trackId) {
    state.activeTrackId = trackId;
    state.cues = [];
    state.translations = [];
    state.fallback = false;
    state.status = 'fetching';
    state.lastRenderedKey = null;
    state.referenceTrackId = null;
    state.referenceCues = null;
    state.referenceLines = null;
    if (state.referencePollTimer) { clearTimeout(state.referencePollTimer); state.referencePollTimer = null; }
    pageCommand({ type: 'fetch-track', movieId: state.urlMovieId, trackId: trackId, purpose: 'source' });
  }

  // T4: decide how to handle the current (source track, targetLang) pair
  // before doing any work. Three outcomes:
  //  - 'passthrough': targetLang already matches the source subtitle's own
  //    language — the source text IS the desired output, so skip translation
  //    entirely (no reference fetch, no native call, no model load — this is
  //    also what PLAN.md M3 depends on).
  //  - 'translate' with a referenceTrack: normal T2/T3 flow.
  //  - 'translate' with referenceTrack=null: no official target-language
  //    track exists (or the only candidates were forced/CC, excluded by
  //    findReferenceTrack) — falls back to translating with no reference,
  //    identical to pre-T2 behavior.
  function decideTranslationStrategy() {
    const sourceTrack = state.tracks.find((t) => t.id === state.activeTrackId);
    const sourceLang = sourceTrack ? sourceTrack.language : '';
    if (sourceLang && normalizeBcp47(sourceLang) === normalizeBcp47(settings.targetLang)) {
      dbg('decision: passthrough — source track language already matches targetLang', sourceLang, settings.targetLang);
      return { mode: 'passthrough' };
    }
    const referenceTrack = findReferenceTrack(state.tracks, settings.targetLang, state.activeTrackId);
    dbg('decision: translate', referenceTrack ? 'with reference track ' + referenceTrack.id : '(no official target-language track found)');
    return { mode: 'translate', referenceTrack: referenceTrack };
  }

  // T2/T4: once source cues are in hand, decide the strategy and (for the
  // normal translate path) resolve/fetch the official reference track for
  // the current targetLang before kicking off translation, so the first
  // `episode` message already carries referenceLines. A stuck/failed
  // reference fetch must not block translation forever (5s timeout).
  function beginTranslationPipeline() {
    state.referenceTrackId = null;
    state.referenceCues = null;
    state.referenceLines = null;
    if (state.referencePollTimer) { clearTimeout(state.referencePollTimer); state.referencePollTimer = null; }

    const decision = decideTranslationStrategy();
    if (decision.mode === 'passthrough') {
      state.referenceCues = [];
      state.translations = state.cues.map((c) => c.text);
      state.translatedCount = state.cues.length;
      state.status = 'done';
      state.errorHint = '';
      state.lastRenderedKey = null;
      return;
    }

    const refTrack = decision.referenceTrack;
    if (!refTrack) {
      state.referenceCues = [];
      startEpisodeTranslation();
      return;
    }
    state.referenceTrackId = refTrack.id;
    dbg('reference: fetching', refTrack.id, refTrack.language);
    pageCommand({ type: 'fetch-track', movieId: state.urlMovieId, trackId: refTrack.id, purpose: 'reference' });
    state.referencePollTimer = setTimeout(() => {
      if (state.referenceCues == null) {
        dbg('reference: fetch timed out, proceeding without reference');
        state.referenceCues = [];
        startEpisodeTranslation();
      }
    }, 5000);
  }

  // ---------------------------------------------------------------------------
  // V4: "整理本集單字" trigger (PLAN.md Phase V, docs/vocab-design.md §4/§8)
  // ---------------------------------------------------------------------------

  // Asks inject.js for the show/episode/season metadata via Netflix's
  // private player API (`getVideoTitle` in inject.js — verified against the
  // real-world Subadub extension's approach, see its own comment for why).
  // Resolves to `{seriesTitle, episodeTitle, seasonNumber, episodeNumber}`
  // or null on timeout/any failure — this is a best-effort lookup, not
  // something worth blocking or failing "整理本集單字" (or, since
  // 2026-07-06, ordinary translation caching) over.
  function requestEpisodeTitle(movieId) {
    return new Promise((resolve) => {
      let settled = false;
      // `waiter` (not `resolve` itself) is what gets stored in
      // `pendingTitleRequests` and must be the exact same reference removed
      // on timeout — otherwise the timed-out entry never leaves the map (a
      // leak) and, worse, a later request for the same movieId would attach
      // to that dead entry instead of firing a fresh 'get-title'.
      const waiter = (info) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(info);
      };
      const timer = setTimeout(() => {
        removePendingTitleWaiter(movieId, waiter);
        waiter(null);
      }, 1500);
      // If a lookup for this movieId is already in flight (e.g.
      // startEpisodeTranslation()'s automatic cache-title fetch racing with
      // a user click on "整理本集單字"), just add another waiter instead of
      // firing a second 'get-title' — see `pendingTitleRequests`' doc comment.
      const existing = state.pendingTitleRequests.get(movieId);
      if (existing) {
        existing.push(waiter);
        return;
      }
      state.pendingTitleRequests.set(movieId, [waiter]);
      pageCommand({ type: 'get-title', movieId: movieId });
    });
  }

  function removePendingTitleWaiter(movieId, waiter) {
    const waiters = state.pendingTitleRequests.get(movieId);
    if (!waiters) return;
    const idx = waiters.indexOf(waiter);
    if (idx !== -1) waiters.splice(idx, 1);
    if (!waiters.length) state.pendingTitleRequests.delete(movieId);
  }

  // Last-resort fallback if inject.js's private-API lookup above comes back
  // null (API unavailable / Netflix changed something). document.title is
  // NOT reliable during Netflix playback (this was the original — wrong —
  // primary approach; real usage showed it just falls through to the
  // movieId branch below almost every time), so this is now a fallback of a
  // fallback: strips a trailing "- Netflix"/"| Netflix" suffix if present,
  // and gives up to the raw movieId if what's left is empty or still the
  // generic "Netflix" tab title. Returns the same shape `requestEpisodeTitle`
  // resolves to so callers don't need to branch on which path was used.
  function extractEpisodeTitleFallback() {
    let title = (document.title || '').trim();
    title = title.replace(/\s*[-|]\s*Netflix\s*$/i, '').trim();
    if (!title || /^netflix$/i.test(title)) title = state.urlMovieId;
    return { seriesTitle: title, episodeTitle: null, seasonNumber: null, episodeNumber: null };
  }

  // Packages the transcript this tab already holds and hands it to appex via
  // native `save-transcript`, then asks appex to wake/foreground the App on
  // the vocab tab (native `open-app`). Both native calls go through
  // background.js — content.js has no native-messaging channel of its own
  // (see CLAUDE.md's protocol table).
  async function organizeVocab() {
    if (!state.urlMovieId || !state.cues.length) {
      return { ok: false, error: 'no-episode' };
    }
    const sourceTrack = state.tracks.find((t) => t.id === state.activeTrackId);
    const sourceLang = (sourceTrack && sourceTrack.language) || '';
    // vocab-design.md §4: bcp47-based gate, not text-content language
    // detection. popup.js already disables the button for non-English
    // tracks using the same tracks/activeTrackId data from get-status; this
    // is the content.js-side mirror of that check, in case the button state
    // is stale (e.g. the popup was left open across a track switch).
    if (normalizeBcp47(sourceLang) !== 'en') {
      return { ok: false, error: 'non-english' };
    }
    const movieId = state.urlMovieId;
    const titleInfo = (await requestEpisodeTitle(movieId)) || extractEpisodeTitleFallback();
    const payload = {
      movieId: movieId,
      seriesTitle: titleInfo.seriesTitle || movieId,
      episodeTitle: titleInfo.episodeTitle,
      seasonNumber: titleInfo.seasonNumber,
      sourceLang: sourceLang,
      targetLang: settings.targetLang,
      lines: state.cues.map((c) => c.text)
    };
    try {
      return await api.runtime.sendMessage({ type: 'organize-vocab', payload: payload });
    } catch (e) {
      return { ok: false, error: 'native-unavailable' };
    }
  }

  // ---------------------------------------------------------------------------
  // Background port (translation pipeline)
  // ---------------------------------------------------------------------------
  function getPort() {
    if (state.port) return state.port;
    const port = api.runtime.connect({ name: 'multisub' });
    port.onMessage.addListener(onPortMessage);
    port.onDisconnect.addListener(() => {
      state.port = null;
      // Reconnect and resume if we were mid-translation (partial results are
      // cached by the background script, so resuming is cheap).
      if (state.status === 'translating') {
        setTimeout(() => { if (state.status === 'translating') startEpisodeTranslation(); }, 1500);
      }
    });
    state.port = port;
    return port;
  }

  function startEpisodeTranslation() {
    if (!state.cues.length || !state.urlMovieId) return;
    if (!settings.enabled) return; // M1: don't spend model calls while translation is toggled off
    if (state.referenceCues == null) return; // reference still resolving; beginTranslationPipeline() will call back in
    const referenceLines = state.referenceCues.length
      ? alignReferenceCues(state.cues, state.referenceCues)
      : new Array(state.cues.length).fill(null);
    state.referenceLines = referenceLines;
    if (DEBUG && state.referenceCues.length) {
      dbg('reference-align sample (', state.referenceCues.length, 'ref cues ):');
      for (const idx of pickSampleIndices(state.cues.length, 10)) {
        dbg('  [' + idx + ']', JSON.stringify(state.cues[idx].text).slice(0, 60),
            '->', JSON.stringify(referenceLines[idx]).slice(0, 60));
      }
    }
    const sourceTrack = state.tracks.find((t) => t.id === state.activeTrackId);
    const sourceLang = (sourceTrack && sourceTrack.language) || '';
    state.translations = new Array(state.cues.length).fill(null);
    state.translatedCount = 0;
    state.status = 'translating';
    state.errorHint = '';
    try {
      getPort().postMessage({
        type: 'episode',
        movieId: state.urlMovieId,
        targetLang: settings.targetLang,
        sourceLang: sourceLang,
        lines: state.cues.map((c) => c.text),
        referenceLines: referenceLines
      });
    } catch (e) {
      state.port = null;
      setTimeout(startEpisodeTranslation, 1500);
      return;
    }
    // 2026-07-06: separate, fire-and-forget title lookup so a slow/failed
    // private-API call (up to the 1.5s timeout in requestEpisodeTitle) never
    // delays subtitles starting to appear above. Sent as its own port
    // message once resolved; background.js attaches it to this episode's
    // cache entry for the App's cache-management tab (real titles + grouping
    // by series — see CLAUDE.md's Port "multisub" protocol entry).
    fetchAndStoreEpisodeTitle(state.urlMovieId, sourceLang);
  }

  async function fetchAndStoreEpisodeTitle(movieId, sourceLang) {
    const titleInfo = (await requestEpisodeTitle(movieId)) || extractEpisodeTitleFallback();
    try {
      getPort().postMessage({
        type: 'episode-title',
        movieId: movieId,
        sourceLang: sourceLang,
        targetLang: settings.targetLang,
        seriesTitle: titleInfo.seriesTitle || movieId,
        episodeTitle: titleInfo.episodeTitle,
        seasonNumber: titleInfo.seasonNumber
      });
    } catch (e) { /* port gone; harmless, cache entry just won't have a title yet */ }
  }

  function onPortMessage(msg) {
    if (msg.type === 'progress') {
      if (!Array.isArray(msg.translations)) return;
      for (let i = 0; i < msg.translations.length; i++) {
        const idx = msg.start + i;
        if (idx < state.translations.length && msg.translations[i] != null) {
          if (state.translations[idx] == null) state.translatedCount++;
          state.translations[idx] = msg.translations[i];
        }
      }
      state.lastRenderedKey = null; // re-render current cue if it just got translated
    } else if (msg.type === 'done') {
      state.status = 'done';
    } else if (msg.type === 'error') {
      if (msg.code === 'native-unavailable') {
        state.errorHint = 'MultiSub：無法連到主程式，請開啟 MultiSub App';
      } else if (msg.code === 'model-not-ready') {
        state.errorHint = 'MultiSub：模型尚未下載，請開啟 MultiSub App 完成下載';
      } else {
        state.errorHint = 'MultiSub：翻譯失敗（' + (msg.code || 'unknown') + '）';
      }
      state.status = 'error';
      state.lastRenderedKey = null;
    } else if (msg.type === 'line-result') {
      dbg('fallback: line-result:', JSON.stringify(msg).slice(0, 160));
      if (msg.text != null && msg.translation != null) {
        state.fallbackCache.set(msg.text, msg.translation);
        state.fallbackInflight.delete(msg.text);
        state.lastRenderedKey = null;
      }
      if (msg.code) {
        state.fallbackInflight.delete(msg.text);
        if (msg.code === 'native-unavailable') {
          state.errorHint = 'MultiSub：無法連到主程式，請開啟 MultiSub App';
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // DOM fallback: translate whatever Netflix renders, line by line.
  // ---------------------------------------------------------------------------
  function enableFallback(reason) {
    state.fallback = true;
    state.status = 'fallback';
    console.log('[MultiSub] falling back to DOM subtitles:', reason);
  }

  function readDomSubtitle() {
    const container = document.querySelector('.player-timedtext');
    if (!container) return '';
    return (container.textContent || '').trim();
  }

  // A3 diagnosis: probe the live Netflix DOM for where the native subtitle text
  // actually lives and whether our overlay is attached/visible.
  let debugProbeSig = '';
  function debugProbe(video) {
    if (!DEBUG) return;
    const dom = readDomSubtitle();
    const overlayTxt = overlayText ? overlayText.textContent : '';
    // Only log when something meaningful changes, to avoid flooding.
    const sig = state.status + '|' + state.fallback + '|' + dom + '|' + overlayTxt + '|' + state.errorHint;
    if (sig === debugProbeSig) return;
    debugProbeSig = sig;
    dbg('probe: status=', state.status, 'fallback=', state.fallback,
        'cues=', state.cues.length, 'fallbackCache=', state.fallbackCache.size,
        'DOM=', JSON.stringify(dom).slice(0, 70),
        'OVERLAY=', JSON.stringify(overlayTxt).slice(0, 70),
        'overlayDisplay=', overlay ? overlay.style.display : 'none',
        'errorHint=', JSON.stringify(state.errorHint));
  }

  function requestLineTranslation(text) {
    if (state.fallbackCache.has(text) || state.fallbackInflight.has(text)) return;
    state.fallbackInflight.add(text);
    dbg('fallback: request line translation:', JSON.stringify(text).slice(0, 60));
    try {
      getPort().postMessage({ type: 'line', text: text, targetLang: settings.targetLang });
    } catch (e) {
      dbg('fallback: postMessage failed', e && e.message);
      state.port = null;
      state.fallbackInflight.delete(text);
    }
  }

  // ---------------------------------------------------------------------------
  // Overlay
  // ---------------------------------------------------------------------------
  let overlay = null;
  let overlayOriginal = null;
  let overlayText = null;
  let overlayHint = null;

  function buildOverlay() {
    overlay = document.createElement('div');
    overlay.id = 'multisub-overlay';
    // D3: original line goes first in DOM order so the translation
    // (#multisub-text) stays the bottom-most child — its position is what
    // bottomOffset/D2's drag calibrate against, on or off merged mode.
    overlayOriginal = document.createElement('div');
    overlayOriginal.id = 'multisub-original';
    overlayText = document.createElement('div');
    overlayText.id = 'multisub-text';
    overlayHint = document.createElement('div');
    overlayHint.id = 'multisub-hint';
    overlay.appendChild(overlayOriginal);
    overlay.appendChild(overlayText);
    overlay.appendChild(overlayHint);
    overlayText.addEventListener('pointerdown', onDragPointerDown);
    overlayText.addEventListener('pointermove', onDragPointerMove);
    overlayText.addEventListener('pointerup', onDragPointerUp);
    overlayText.addEventListener('pointercancel', onDragPointerUp);
    applySettingsToOverlay();
    updateDragAffordance();
  }

  // ---------------------------------------------------------------------------
  // D2: drag-to-position. Only reachable when dragModeEnabled, since
  // #multisub-text is pointer-events:none otherwise (see overlay.css's
  // .multisub-drag-enabled) — the `if (!state.dragModeEnabled) return;` guards
  // below are defensive, not the actual gate.
  // ---------------------------------------------------------------------------
  let dragState = null;

  function updateDragAffordance() {
    if (!overlay) return;
    overlay.classList.toggle('multisub-drag-enabled', state.dragModeEnabled);
  }

  function onDragPointerDown(ev) {
    if (!state.dragModeEnabled) return;
    const container = overlay.parentElement;
    if (!container) return;
    const containerHeight = container.getBoundingClientRect().height;
    if (!containerHeight) return; // avoid a NaN% offset if the container isn't laid out yet
    ev.preventDefault();
    overlayText.setPointerCapture(ev.pointerId);
    dragState = {
      pointerId: ev.pointerId,
      startY: ev.clientY,
      containerHeight: containerHeight,
      startOffset: settings.bottomOffset,
      currentValue: settings.bottomOffset
    };
  }

  function onDragPointerMove(ev) {
    if (!dragState || ev.pointerId !== dragState.pointerId) return;
    // Moving the pointer down should bring the subtitle closer to the
    // bottom edge, i.e. decrease bottomOffset — hence the minus sign.
    const deltaPercent = ((ev.clientY - dragState.startY) / dragState.containerHeight) * 100;
    let next = Math.round(dragState.startOffset - deltaPercent);
    next = Math.max(DRAG_MIN_OFFSET, Math.min(DRAG_MAX_OFFSET, next));
    dragState.currentValue = next;
    overlay.style.setProperty('--multisub-bottom', next + '%');
  }

  function onDragPointerUp(ev) {
    if (!dragState || ev.pointerId !== dragState.pointerId) return;
    const finalValue = dragState.currentValue;
    dragState = null;
    // Only touch storage once, on release — not on every pointermove.
    if (finalValue !== settings.bottomOffset) {
      settings = Object.assign({}, settings, { bottomOffset: finalValue });
      api.storage.local.set({ settings: settings }).catch(() => {});
    }
  }

  function applySettingsToOverlay() {
    if (!overlay) return;
    overlay.style.setProperty('--multisub-bottom', settings.bottomOffset + '%');
    overlay.style.setProperty('--multisub-font-scale', String(settings.fontScale));
    const st = Object.assign({}, DEFAULT_STYLES, settings.styles || {});
    overlay.style.setProperty('--multisub-color', st.textColor);
    overlay.style.setProperty('--multisub-bg', hexToRgba(st.backgroundColor, st.backgroundOpacity));
    overlay.style.setProperty('--multisub-font', st.fontFamily);
    overlay.style.setProperty('--multisub-line-height', String(st.lineHeight));
    overlay.style.setProperty('--multisub-outline', outlineShadow(st.outlineEnabled, st.outlineColor));
    overlay.style.setProperty('--multisub-font-weight', st.boldEnabled ? 'bold' : 'normal');
    overlay.style.display = settings.enabled ? '' : 'none';
    // D3: hide Netflix's own subtitle line only while the extension is on
    // and merged mode is enabled — see overlay.css's html.multisub-native-hidden rule.
    document.documentElement.classList.toggle('multisub-native-hidden', settings.enabled && !!settings.mergedMode);
  }

  function ensureOverlayAttached(video) {
    if (!overlay) buildOverlay();
    const container = video.closest('.watch-video') || video.parentElement;
    if (!container) { dbg('ensureOverlayAttached: no container found for video'); return; }
    if (overlay.parentElement !== container) {
      const cs = getComputedStyle(container);
      if (cs.position === 'static') container.style.position = 'relative';
      container.appendChild(overlay);
    }
  }

  // C6: renders each \n-separated line as its own '.ms-line' child instead of
  // one text node relying on CSS white-space:pre-wrap — lets overlay.css keep
  // the background box snug to the glyphs regardless of --multisub-line-height
  // (see overlay.css's #multisub-text/#multisub-original comment).
  function setOverlayLines(container, text) {
    container.textContent = '';
    if (!text) return;
    for (const line of text.split('\n')) {
      const div = document.createElement('div');
      div.className = 'ms-line';
      div.textContent = line;
      container.appendChild(div);
    }
  }

  function renderOverlay(text, hint, original) {
    // D3: only show the original line in merged mode; otherwise Netflix's
    // own native subtitle (not hidden in that case) already shows it.
    const showOriginal = !!settings.mergedMode && !!original;
    const key = text + ' ' + hint + ' ' + (showOriginal ? original : '');
    if (state.lastRenderedKey === key) return;
    state.lastRenderedKey = key;
    setOverlayLines(overlayText, text);
    // NB: the stylesheet sets #multisub-text{display:none}; clearing the inline
    // style ('') would revert to that and stay hidden — must set 'flex'
    // (C6: the box is now flex-column, see overlay.css).
    overlayText.style.display = text ? 'flex' : 'none';
    overlayHint.textContent = hint;
    overlayHint.style.display = hint ? 'block' : 'none';
    setOverlayLines(overlayOriginal, showOriginal ? original : '');
    overlayOriginal.style.display = showOriginal ? 'flex' : 'none';
  }

  // ---------------------------------------------------------------------------
  // Sync loop
  // ---------------------------------------------------------------------------
  function findCueIndex(t) {
    const cues = state.cues;
    let lo = 0, hi = cues.length - 1, ans = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (cues[mid].start <= t) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    // Keep the subtitle up a touch longer to bridge tiny gaps between cues.
    if (ans >= 0 && t <= cues[ans].end + 0.15) return ans;
    return -1;
  }

  function tick() {
    checkUrl();
    if (!state.urlMovieId) return; // not on a watch page
    const video = document.querySelector('video');
    if (!video) return;
    ensureOverlayAttached(video);
    debugProbe(video);
    if (!settings.enabled) return;

    let text = '';
    let original = '';
    if (!state.fallback && state.cues.length) {
      const idx = findCueIndex(video.currentTime);
      if (idx >= 0) {
        const tr = state.translations[idx];
        text = tr != null ? tr : '';
        original = state.cues[idx].text || '';
      }
    } else if (state.fallback) {
      original = readDomSubtitle();
      state.fallbackCurrentText = original;
      if (original) {
        if (state.fallbackCache.has(original)) {
          text = state.fallbackCache.get(original);
        } else {
          requestLineTranslation(original);
        }
      }
    }
    renderOverlay(text, state.errorHint, original);
  }

  // ---------------------------------------------------------------------------
  // SPA navigation / episode change detection
  // ---------------------------------------------------------------------------
  function currentUrlMovieId() {
    const m = location.pathname.match(/^\/watch\/(\d+)/);
    return m ? m[1] : null;
  }

  function checkUrl() {
    const id = currentUrlMovieId();
    if (id === state.urlMovieId) return;
    resetForMovie(id);
  }

  function resetForMovie(movieId) {
    dbg('resetForMovie ->', movieId);
    state.urlMovieId = movieId;
    state.tracks = [];
    state.activeTrackId = null;
    state.netflixActiveBcp47 = null;
    state.cues = [];
    state.referenceTrackId = null;
    state.referenceCues = null;
    state.referenceLines = null;
    if (state.referencePollTimer) { clearTimeout(state.referencePollTimer); state.referencePollTimer = null; }
    state.translations = [];
    state.translatedCount = 0;
    state.status = movieId ? 'waiting-tracks' : 'idle';
    state.errorHint = '';
    state.fallback = false;
    state.fallbackCache.clear();
    state.fallbackInflight.clear();
    state.lastRenderedKey = null;
    if (overlay) renderOverlay('', '');
    if (state.trackPollTimer) { clearInterval(state.trackPollTimer); state.trackPollTimer = null; }
    if (!movieId) return;

    // The manifest may already have been captured (or not arrived yet):
    // poll the page script for tracks until they show up.
    let attempts = 0;
    state.trackPollTimer = setInterval(() => {
      attempts++;
      if (state.tracks.length || attempts > 15) {
        clearInterval(state.trackPollTimer);
        state.trackPollTimer = null;
        if (!state.tracks.length && !state.cues.length) enableFallback('tracks-timeout');
        return;
      }
      pageCommand({ type: 'get-tracks', movieId: movieId });
    }, 2000);
    pageCommand({ type: 'get-tracks', movieId: movieId });
  }

  setInterval(tick, 100);

  // M2: the appex host's idle-unload check (Translator.checkIdleUnload)
  // only runs when a native message wakes that process — it has no
  // reliable internal timer of its own (the OS suspends the extension host
  // between requests). Ping periodically whenever a Netflix watch page is
  // open so a paused/idle session still gets checked even with the popup
  // closed; background.js already forwards 'ping-native' to the native
  // `ping` action, which triggers the check as a side effect.
  setInterval(() => {
    if (!state.urlMovieId) return;
    // D1: also a low-frequency fallback style sync for when the popup isn't
    // open (popup.js's own 2s poll is the primary, faster path — see D1).
    api.runtime.sendMessage({ type: 'ping-native' }).then(mergeStylesFromNative).catch(() => {});
  }, 60000);

  // ---------------------------------------------------------------------------
  // Popup messaging
  // ---------------------------------------------------------------------------
  api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.type === 'get-status') {
      sendResponse({
        onWatchPage: !!state.urlMovieId,
        movieId: state.urlMovieId,
        tracks: state.tracks,
        activeTrackId: state.activeTrackId,
        sourceMode: state.sourceMode,
        status: state.status,
        translatedCount: state.translatedCount,
        totalCues: state.cues.length,
        errorHint: state.errorHint,
        dragMode: state.dragModeEnabled
      });
    } else if (msg && msg.type === 'set-track') {
      state.sourceMode = 'manual';
      switchToTrack(msg.trackId);
      sendResponse({ ok: true });
    } else if (msg && msg.type === 'set-track-auto') {
      state.sourceMode = 'auto';
      let track = null;
      if (state.netflixActiveBcp47) track = findTrackByBcp47(state.tracks, state.netflixActiveBcp47);
      if (!track) track = chooseTrack(state.tracks);
      if (track) switchToTrack(track.id);
      sendResponse({ ok: true });
    } else if (msg && msg.type === 'set-drag-mode') {
      state.dragModeEnabled = !!msg.enabled;
      updateDragAffordance();
      sendResponse({ ok: true });
    } else if (msg && msg.type === 'organize-vocab') {
      organizeVocab().then(sendResponse);
      return true; // async response
    }
    return false;
  });
})();

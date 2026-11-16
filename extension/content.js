// Content script (isolated world) for netflix.com. Loaded after shared.js.
//
// What it does, by section:
//  1. Setup and state.
//  2. Settings and native sync: settings from storage.local, styles,
//     preferences and engine status from the native `ping`.
//  3. Page-world messages: track lists, cues and the player's selected tracks
//     reported by inject.js.
//  4. Track selection: the primary (original-language) track and the
//     second-language track.
//  5. Pipelines per mode (netflix / translate / annotate) and the job port to
//     background.js.
//  6. DOM fallback: when no track data was captured, work from the subtitle
//     text Netflix renders, line by line.
//  7. Overlay rendering, including drag-to-position.
//  8. The one-time toast on the first watch page.
//  9. Sync loop (renders the cue at video.currentTime, detects seeks).
// 10. Navigation between episodes.
// 11. Popup messaging and the vocabulary hand-off.
(() => {
  'use strict';
  const api = typeof browser !== 'undefined' ? browser : chrome;
  const MS = globalThis.MS;
  if (!MS) return; // shared.js didn't load; nothing below can work without it

  const DEBUG = false;
  function dbg() {
    if (!DEBUG) return;
    try { console.log.apply(console, ['[MultiSub][content]'].concat([].slice.call(arguments))); } catch (e) { /* ignore */ }
  }

  // ===========================================================================
  // 1. Setup and state
  // ===========================================================================

  // Must match popup.html's #bottomOffset slider min/max.
  const DRAG_MIN_OFFSET = 0;
  const DRAG_MAX_OFFSET = 40;
  // A jump in currentTime bigger than this between two ticks is a seek.
  const SEEK_JUMP_SEC = 20;
  // Safari unloads the background page 30 s after its last event and doesn't
  // count a pending native call, but it does count port traffic.
  const KEEPALIVE_MS = 15000;
  const NATIVE_PING_MS = 60000;
  // A stuck second-language fetch must not hold translation back forever.
  const SECOND_TRACK_TIMEOUT_MS = 5000;
  // How long a fresh track list waits for the player to report which
  // subtitle the viewer has selected, so we don't start a job on the wrong
  // track and pay for it twice.
  const ACTIVE_TRACK_WAIT_MS = 1500;
  // How long a page with nothing chosen in the extension waits for the first
  // native ping before running the default mode (see waitingForAppPrefs). A
  // cold app extension can take a couple of seconds; same as popup.js.
  const FIRST_PING_WAIT_MS = 3000;
  const NOTICE_MS = 8000;
  // Each term is glossed for its first few annotated cues only, so repeated
  // words stop cluttering the line.
  const GLOSS_REPEAT_LIMIT = 3;
  const FALLBACK_CACHE_MAX = 2000;
  const FALLBACK_ERROR_PAUSE_MS = 10000;
  const AUTO_RETRY_MS = 30000;
  const AUTO_RETRY_MAX = 5;
  // A failed download of the primary track is retried this many times (after
  // these delays) before falling back to reading Netflix's rendered text: a
  // CDN hiccup shouldn't cost the whole episode its full-track mode, and an
  // expired URL is replaced once Netflix fetches a fresh manifest.
  const PRIMARY_FETCH_RETRY_MS = [2000, 6000];
  // After a fetch failure put the episode in fallback, a fresh track list
  // from Netflix gets this many more tries at the full track.
  const FALLBACK_RECOVERY_MAX = 2;
  // Errors that a different engine setup can fix: retry when it changes.
  const ENGINE_FIXABLE_CODES = new Set(['engine-not-ready', 'model-not-ready', 'auth-failed', 'consent-required', 'native-unavailable']);
  // Errors that may clear up by themselves: retry after a pause.
  const AUTO_RETRY_CODES = new Set(['rate-limited', 'network', 'provider-error', 'native-unavailable']);

  const TEXT = {
    noData: '沒有抓到字幕資料，請重新整理頁面（⌘R）',
    noSecond: (lang) => '這部片沒有 Netflix 官方的' + MS.languageName(lang) + '字幕，可在 MultiSub 選單改用「AI 翻譯」',
    toastTitle: 'MultiSub 已開啟',
    // The two bilingual modes' labels start with Latin letters, hence the space.
    toastBody: (mode, lang) => mode === 'annotate'
      ? '目前使用生字標註，難字後面會標上' + MS.languageName(lang) + '的意思。'
      : '目前使用 ' + MS.modeById(mode).label + '，第二語言是' + MS.languageName(lang) + '。',
    toastHint: '點 Safari 工具列的 MultiSub 按鈕可以換模式。',
    toastClose: '關閉',
    // A job that finished with some chunks failed (see background.js runJob).
    partial: (kind, retrying) => 'MultiSub：有部分字幕' + (kind === 'annotate' ? '標註' : '翻譯') +
      '失敗' + (retrying ? '，稍後會自動補上' : '')
  };

  let settings = MS.mergeSettings(null);

  const state = {
    // --- episode and tracks
    urlMovieId: null,
    tracks: [],
    tracksAt: 0,
    activeTrackId: null, // primary track
    sourceMode: 'auto', // 'auto' (follow Netflix's player) | 'manual' (picked in the popup)
    manualTrackId: null,
    activeTrackReported: false,
    netflixActiveBcp47: null, // subtitle selected in Netflix's player, null = off/unknown
    netflixActiveForced: false, // ...and it is a forced-narrative track
    netflixAudioBcp47: null,
    selectTimer: null,
    trackPollTimer: null,
    cues: [], // primary track cues [{start, end, text}]
    primaryRetries: 0, // failed fetches of the current primary track
    primaryRetryTimer: null,
    fallbackReason: null,
    fallbackRecoveries: 0,
    secondTrackId: null,
    secondState: 'unknown', // unknown | loading | ready | none | failed
    secondCues: [],
    secondTimer: null,
    secondTimedOut: false,
    // --- pipeline
    status: 'idle', // idle | off | waiting-tracks | fetching | ready | translating | annotating | done | passthrough | fallback | error
    errorCode: null,
    errorHint: '',
    itemsKind: null,
    items: [], // per cue: translation (string) or annotations ([{term, gloss}]); null = pending
    readyCount: 0,
    glossPlan: null,
    glossPlanDirty: true,
    segMemo: null,
    job: null, // { kind, msg, finished }
    partialMissing: 0, // lines the last finished job couldn't do (done.partial)
    waitingForReference: false,
    port: null,
    reconnectTimer: null,
    reconnectAttempts: 0,
    retryTimer: null,
    autoRetries: 0,
    lastVideoTime: null,
    // --- DOM fallback
    fallback: false,
    fallbackCache: new Map(), // kind + '\0' + text -> translation | annotations
    fallbackInflight: new Set(),
    fallbackPausedUntil: 0,
    fallbackGlossCounts: new Map(),
    fallbackGlossPlan: new Map(),
    // --- overlay and UI
    lastRenderedKey: null,
    nativeHidden: false,
    notice: null, // { text, until }
    noSecondHintShown: false,
    noDataHintShown: false,
    // Drag mode lives only here (not storage.local) so it can't linger
    // enabled across page reloads; the popup reads it back via get-status.
    dragModeEnabled: false,
    // --- native
    // The first ping answered (or FIRST_PING_WAIT_MS passed without one).
    startupPingDone: false,
    // startPipeline() was called while waitingForAppPrefs() held, so the
    // pipeline still has to start once the wait is over.
    pipelineHeld: false,
    nativeOk: null,
    engine: null,
    engineSig: null,
    // movieId -> [resolver, ...] for in-flight 'get-title' round trips with
    // inject.js. Must allow several waiters per movieId: a job start fires
    // one lookup automatically for the cache title, and clicking
    // 「整理本集單字」 while that is still in flight fires a second. With a
    // single slot the second overwrote the first, which then timed out and
    // stored the wrong title.
    pendingTitleRequests: new Map()
  };

  // The one-time toast (section 8). `seen` is null until storage.local has
  // been read, then whether this install has shown it already.
  const toast = { host: null, root: null, timer: null, seen: null };

  function primaryTrack() {
    return state.tracks.find((t) => t.id === state.activeTrackId) || null;
  }

  function primaryLanguage() {
    const t = primaryTrack();
    return (t && t.language) || '';
  }

  function getVideo() {
    return document.querySelector('video');
  }

  function pageCommand(msg) {
    window.postMessage(Object.assign({ __multisub_cmd: true }, msg), '*');
  }

  // Fallback injection of the page-world script. inject.js is also declared
  // as a `world: "MAIN"` content script, which runs earlier; whichever runs
  // second sees the page-world flag and exits.
  function injectPageScript() {
    try {
      const s = document.createElement('script');
      s.src = api.runtime.getURL('inject.js');
      s.onload = () => s.remove();
      (document.head || document.documentElement).appendChild(s);
    } catch (e) { dbg('script injection failed:', e && e.message); }
  }
  injectPageScript();

  // ===========================================================================
  // 2. Settings and native sync
  // ===========================================================================

  // Applies settings right away, so the caller can rely on them being in
  // effect when this returns (onNativePing does), then writes them. The
  // storage.onChanged listener below applies the written copy once more;
  // that's a no-op, since nothing compared there has changed.
  function saveSettings(next) {
    applySettingsChange(next);
    return api.storage.local.set({ settings: MS.storedSettings(next) }).catch(() => {});
  }

  function applySettingsChange(next) {
    const prev = settings;
    settings = next;
    applySettingsToOverlay();
    // A mode or language picked in the popup while the toast is up.
    if (toast.host) {
      if (next.enabled) renderToastText();
      else removeToast();
    }
    const langChanged = prev.targetLang !== next.targetLang;
    const modeChanged = prev.mode !== next.mode;
    if (langChanged || modeChanged) {
      // A notice about the old mode or language (no official track in it,
      // some lines of the old job missing) no longer applies.
      state.notice = null;
      state.lastRenderedKey = null;
    }
    if (langChanged) {
      // The second-language track depends on the target language, and so
      // does the primary (it avoids the target language), so re-select both.
      clearFallbackResults();
      state.noSecondHintShown = false;
      if (state.tracks.length && !state.fallback) selectTracks({ restart: true });
      else startPipeline();
    } else {
      const levelChanged = prev.annotateLevel !== next.annotateLevel && next.mode === 'annotate';
      if (levelChanged) clearFallbackResults();
      if (prev.enabled !== next.enabled || modeChanged || levelChanged) startPipeline();
    }
    // Something picked in the popup (stamped) ends the wait for the app's
    // preferences.
    resumeHeldPipeline();
  }

  api.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !changes.settings) return;
    applySettingsChange(MS.mergeSettings(changes.settings.newValue));
  });

  function stylesEqual(a, b) {
    return Object.keys(MS.DEFAULT_STYLES).every((k) => (a || {})[k] === (b || {})[k]);
  }

  function engineSignature(engine) {
    if (!engine) return 'none';
    return [engine.active, engine.provider, engine.model, engine.hasKey, engine.localModelDownloaded].join('|');
  }

  function pingNative() {
    let p;
    try { p = api.runtime.sendMessage({ type: 'ping-native' }); } catch (e) { p = Promise.reject(e); }
    return Promise.resolve(p).then(onNativePing, () => onNativePing(null));
  }

  // Whether the pipeline waits for the app's preferences before running
  // anything: nothing has been chosen in the extension, so the mode and
  // language in `settings` are only defaults, and the first native ping
  // hasn't answered yet. The app may well hold a choice (say, AI 翻譯 picked
  // during onboarding right before opening Netflix); running the default
  // mode meanwhile would draw the wrong subtitles, hide Netflix's own, and
  // could put up the netflix-mode hint suggesting the very mode the app
  // chose. Bounded by FIRST_PING_WAIT_MS.
  function waitingForAppPrefs() {
    return !state.startupPingDone && !settings.prefsUpdatedAt;
  }

  // Starts a pipeline that was held back by waitingForAppPrefs(), once the
  // wait is over. A no-op otherwise, including when a settings change
  // already restarted it.
  function resumeHeldPipeline() {
    if (state.pipelineHeld && !waitingForAppPrefs()) startPipeline();
  }

  function endStartupWait() {
    state.startupPingDone = true;
    resumeHeldPipeline();
  }

  // Applies a native `ping` reply: subtitle styles (owned by the app), the
  // shared preferences (newest updatedAt wins) and the engine status.
  function onNativePing(res) {
    state.startupPingDone = true;
    if (!res || !res.ok) {
      state.nativeOk = false;
      endStartupWait();
      return;
    }
    const nativeCameBack = state.nativeOk === false;
    state.nativeOk = true;
    const prevSig = state.engineSig;
    state.engine = res.engine || null;
    state.engineSig = engineSignature(state.engine);

    let next = settings;
    if (res.styles && !stylesEqual(res.styles, settings.styles)) {
      next = Object.assign({}, next, { styles: Object.assign({}, MS.DEFAULT_STYLES, res.styles) });
    }
    const rec = MS.reconcilePrefs(next, res.prefs);
    if (rec.adopt) next = Object.assign({}, rec.adopt, { styles: next.styles });
    // Applied synchronously: a mode the app chose restarts the pipeline in
    // there, and endStartupWait() below only starts it when nothing did.
    if (next !== settings) saveSettings(next);
    if (rec.push) sendPrefs(next);
    endStartupWait();

    // A job that failed for lack of a working engine gets another go once
    // the engine setup changed (e.g. a key was pasted in the app).
    const engineChanged = prevSig !== null && prevSig !== state.engineSig;
    if (state.status === 'error' && ENGINE_FIXABLE_CODES.has(state.errorCode) &&
        (engineChanged || (nativeCameBack && state.errorCode === 'native-unavailable'))) {
      startPipeline();
    }
  }

  function sendPrefs(s) {
    try {
      Promise.resolve(api.runtime.sendMessage({ type: 'set-prefs', prefs: MS.prefsOf(s) })).catch(() => {});
    } catch (e) { /* background unreachable; the next ping pushes again */ }
  }

  // Startup: settings first, then ask native right away so styles,
  // preferences and the engine status apply without waiting for the
  // periodic ping. A ping that never answers (the app's extension stuck or
  // missing) must not keep the default mode from running.
  api.storage.local.get('settings')
    .then((res) => applySettingsChange(MS.mergeSettings(res && res.settings)))
    .catch(() => applySettingsChange(MS.mergeSettings(null)))
    .then(() => pingNative());
  setTimeout(endStartupWait, FIRST_PING_WAIT_MS);

  // The native side's idle-unload check for the local model only runs when a
  // native message wakes that process (it has no reliable timer of its own),
  // so keep pinging while a watch page is open, even with the popup closed.
  // Doubles as a slow style/preference sync when the popup isn't open.
  setInterval(() => {
    if (state.urlMovieId) pingNative();
  }, NATIVE_PING_MS);

  // ===========================================================================
  // 3. Page-world messages
  // ===========================================================================
  window.addEventListener('message', (ev) => {
    if (ev.source !== window) return;
    const msg = ev.data;
    if (!msg || msg.__multisub !== true) return;
    if (msg.type === 'tracks') onTracks(msg);
    else if (msg.type === 'cues') onCues(msg);
    else if (msg.type === 'track-error') onTrackError(msg);
    else if (msg.type === 'active-track') onActiveTrack(msg);
    else if (msg.type === 'title') onTitle(msg);
  });

  function onTracks(msg) {
    if (!state.urlMovieId || msg.movieId !== state.urlMovieId) return; // prefetch of another episode
    state.tracks = Array.isArray(msg.tracks) ? msg.tracks : [];
    dbg('tracks for', msg.movieId, state.tracks);
    if (state.trackPollTimer) { clearInterval(state.trackPollTimer); state.trackPollTimer = null; }
    if (!state.tracks.length) return;
    if (!state.tracksAt) state.tracksAt = Date.now();
    // The episode fell back to DOM text because the track download failed.
    // inject.js re-posts the list when Netflix fetches a fresh manifest
    // (new URLs) after such a failure: give the full track another go.
    if (state.fallback && state.fallbackReason === 'fetch-failed' &&
        state.fallbackRecoveries < FALLBACK_RECOVERY_MAX) {
      state.fallbackRecoveries++;
      state.activeTrackId = null; // makes selectTracks fetch it again
      state.primaryRetries = 0;
    }
    scheduleSelectTracks();
  }

  function onActiveTrack(msg) {
    if (msg.movieId !== state.urlMovieId) return;
    dbg('active-track', msg.bcp47, msg.displayName, 'audio', msg.audioBcp47);
    state.activeTrackReported = true;
    state.netflixActiveBcp47 = msg.bcp47 || null;
    state.netflixActiveForced = !!msg.forced;
    state.netflixAudioBcp47 = msg.audioBcp47 || null;
    state.lastRenderedKey = null; // the layout may change (see netflixDrawsPrimary)
    if (!state.tracks.length) return; // onTracks() selects once the manifest arrives
    if (state.selectTimer) { selectTracks(); return; } // it was waiting for exactly this
    if (state.sourceMode !== 'auto') return; // the viewer picked a track in the popup
    // Subtitles switched off in Netflix's player mid-episode: keep the track
    // we already show instead of restarting the job on another one.
    if (!msg.bcp47 && state.activeTrackId) return;
    selectTracks();
  }

  function onCues(msg) {
    if (msg.movieId !== state.urlMovieId) return;
    if (msg.purpose === 'reference') {
      if (msg.trackId !== state.secondTrackId) return; // superseded by a newer choice
      clearSecondTimer();
      state.secondCues = Array.isArray(msg.cues) ? msg.cues : [];
      state.secondState = state.secondCues.length ? 'ready' : 'failed';
      dbg('second track cues:', state.secondCues.length);
      onSecondSettled();
      return;
    }
    if (msg.trackId !== state.activeTrackId) return; // superseded by a newer track switch
    state.cues = Array.isArray(msg.cues) ? msg.cues : [];
    dbg('primary cues:', state.cues.length);
    if (!state.cues.length) { enableFallback('empty-track'); return; }
    state.fallback = false;
    state.fallbackReason = null;
    state.primaryRetries = 0;
    clearPrimaryRetry();
    startPipeline();
  }

  function onTrackError(msg) {
    if (msg.movieId !== state.urlMovieId) return;
    if (msg.purpose === 'reference') {
      if (msg.trackId !== state.secondTrackId) return;
      clearSecondTimer();
      dbg('second track fetch failed:', msg.error);
      state.secondCues = [];
      state.secondState = 'failed';
      onSecondSettled();
      return;
    }
    if (msg.trackId !== state.activeTrackId || state.cues.length) return;
    if (state.primaryRetries < PRIMARY_FETCH_RETRY_MS.length) {
      const trackId = msg.trackId;
      const delay = PRIMARY_FETCH_RETRY_MS[state.primaryRetries++];
      dbg('primary track fetch failed:', msg.error, '- retrying in', delay, 'ms');
      clearPrimaryRetry();
      state.primaryRetryTimer = setTimeout(() => {
        state.primaryRetryTimer = null;
        if (state.activeTrackId !== trackId || state.cues.length || state.fallback) return;
        pageCommand({ type: 'fetch-track', movieId: state.urlMovieId, trackId: trackId, purpose: 'source' });
      }, delay);
      return;
    }
    enableFallback('fetch-failed', msg.error);
  }

  function clearPrimaryRetry() {
    if (state.primaryRetryTimer) { clearTimeout(state.primaryRetryTimer); state.primaryRetryTimer = null; }
  }

  function onTitle(msg) {
    const waiters = state.pendingTitleRequests.get(msg.movieId);
    if (!waiters) return;
    state.pendingTitleRequests.delete(msg.movieId);
    const info = {
      seriesTitle: msg.seriesTitle || null,
      episodeTitle: msg.episodeTitle || null,
      seasonNumber: typeof msg.seasonNumber === 'number' ? msg.seasonNumber : null,
      episodeNumber: typeof msg.episodeNumber === 'number' ? msg.episodeNumber : null
    };
    for (const waiter of waiters) waiter(info);
  }

  // ===========================================================================
  // 4. Track selection
  // ===========================================================================

  // Among same-language candidates, prefer non-forced, then full subtitles
  // over closed captions. Forced (narrative-only) tracks carry just a handful
  // of cues for foreign-language bits, so picking one by language alone would
  // leave the overlay empty almost the whole episode.
  function preferredTrack(candidates) {
    if (!candidates.length) return null;
    const nonForced = candidates.filter((t) => !t.forced);
    const pool = nonForced.length ? nonForced : candidates;
    return pool.find((t) => /subtitle/i.test(t.trackType)) ||
      pool.find((t) => /closed/i.test(t.trackType)) || pool[0];
  }

  function findTrackByBcp47(tracks, bcp47) {
    if (!bcp47) return null;
    return preferredTrack(tracks.filter((t) => MS.sameLanguage(t.language, bcp47)));
  }

  // Primary = the language being watched. Netflix's selected subtitle,
  // unless it is off or already in the target language (then it would just
  // repeat the second line); then the audio language; then English; then
  // the first full non-forced track.
  function choosePrimaryTrack(tracks) {
    if (state.sourceMode === 'manual' && state.manualTrackId) {
      const picked = tracks.find((t) => t.id === state.manualTrackId);
      if (picked) return picked;
    }
    const target = settings.targetLang;
    const usable = (code) => !!code && !MS.sameLanguage(code, target);
    const candidates = [state.netflixActiveBcp47, state.netflixAudioBcp47, 'en'];
    for (const code of candidates) {
      if (!usable(code)) continue;
      const hit = findTrackByBcp47(tracks, code);
      if (hit) return hit;
    }
    return preferredTrack(tracks.filter((t) => !MS.sameLanguage(t.language, target))) ||
      preferredTrack(tracks);
  }

  // Second line = Netflix's own track in the target language: non-forced,
  // full subtitles preferred over closed captions. Never the primary itself.
  function chooseSecondTrack(tracks, primaryId) {
    const matches = tracks.filter((t) => t.id !== primaryId && !t.forced &&
      MS.sameLanguage(t.language, settings.targetLang));
    return matches.find((t) => /subtitle/i.test(t.trackType)) ||
      matches.find((t) => !/closed/i.test(t.trackType)) || matches[0] || null;
  }

  function scheduleSelectTracks() {
    if (state.selectTimer) return;
    const waited = Date.now() - state.tracksAt;
    if (state.activeTrackReported || state.sourceMode === 'manual' || waited >= ACTIVE_TRACK_WAIT_MS) {
      selectTracks();
      return;
    }
    state.selectTimer = setTimeout(() => {
      state.selectTimer = null;
      selectTracks();
    }, ACTIVE_TRACK_WAIT_MS - waited);
  }

  // Picks both tracks and fetches whichever changed. With nothing changed it
  // leaves a running job alone, unless `restart` (the target language changed).
  function selectTracks(opts) {
    if (state.selectTimer) { clearTimeout(state.selectTimer); state.selectTimer = null; }
    if (!state.tracks.length) return;
    const primary = choosePrimaryTrack(state.tracks);
    if (!primary) { enableFallback('no-suitable-track'); return; }
    const primaryChanged = primary.id !== state.activeTrackId;
    dbg('selectTracks: primary', primary.id, primaryChanged ? '(new)' : '(kept)');
    // A new primary resets the cues and the job; the pipeline restarts once
    // its cues arrive.
    if (primaryChanged) switchToTrack(primary.id);
    const secondChanged = resolveSecondTrack();
    if (!primaryChanged && (secondChanged || (opts && opts.restart))) startPipeline();
  }

  function switchToTrack(trackId) {
    state.activeTrackId = trackId;
    state.cues = [];
    state.fallback = false;
    state.fallbackReason = null;
    state.primaryRetries = 0;
    clearPrimaryRetry();
    stopJob();
    resetItems(null);
    state.errorCode = null;
    state.errorHint = '';
    state.status = 'fetching';
    pageCommand({ type: 'fetch-track', movieId: state.urlMovieId, trackId: trackId, purpose: 'source' });
  }

  function clearSecondTimer() {
    if (state.secondTimer) { clearTimeout(state.secondTimer); state.secondTimer = null; }
  }

  // Returns true when the second-language track changed (and is being fetched).
  function resolveSecondTrack() {
    const second = chooseSecondTrack(state.tracks, state.activeTrackId);
    const id = second ? second.id : null;
    if (id === state.secondTrackId && state.secondState !== 'unknown') return false;
    clearSecondTimer();
    state.secondTrackId = id;
    state.secondCues = [];
    state.secondTimedOut = false;
    if (!id) {
      state.secondState = 'none';
      return true;
    }
    state.secondState = 'loading';
    dbg('second track: fetching', id);
    pageCommand({ type: 'fetch-track', movieId: state.urlMovieId, trackId: id, purpose: 'reference' });
    state.secondTimer = setTimeout(() => {
      state.secondTimer = null;
      if (state.secondState !== 'loading') return;
      dbg('second track: timed out, going on without it');
      state.secondTimedOut = true;
      onSecondSettled();
    }, SECOND_TRACK_TIMEOUT_MS);
    return true;
  }

  function onSecondSettled() {
    state.lastRenderedKey = null;
    if (waitingForAppPrefs()) return; // the held pipeline reads secondState when it starts
    if (settings.mode === 'netflix' && !state.fallback && state.cues.length) {
      state.status = state.secondState === 'loading' ? 'fetching' : 'ready';
      maybeShowNoSecondHint();
      return;
    }
    if (state.waitingForReference) startPipeline();
  }

  // ===========================================================================
  // 5. Pipelines and the job port
  // ===========================================================================

  function resetItems(kind) {
    state.itemsKind = kind;
    state.items = kind ? new Array(state.cues.length).fill(null) : [];
    state.readyCount = 0;
    state.glossPlan = null;
    state.glossPlanDirty = true;
    state.segMemo = null;
    state.lastRenderedKey = null;
  }

  function clearRetryTimer() {
    if (state.retryTimer) { clearTimeout(state.retryTimer); state.retryTimer = null; }
  }

  // Drops the current job. Closing its port is what tells background.js to
  // stop (it cancels a job whose port disconnects), and because every job
  // gets a fresh port, late messages from the old one can't reach the new
  // job's state.
  function stopJob() {
    state.job = null;
    state.waitingForReference = false;
    if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }
    state.reconnectAttempts = 0;
    clearRetryTimer();
    closePort();
  }

  function closePort() {
    const port = state.port;
    state.port = null;
    state.fallbackInflight.clear();
    if (port) { try { port.disconnect(); } catch (e) { /* already gone */ } }
  }

  function openPort() {
    if (state.port) return state.port;
    let port;
    try { port = api.runtime.connect({ name: 'multisub' }); } catch (e) { return null; }
    port.onMessage.addListener((msg) => { if (state.port === port && msg) onPortMessage(msg); });
    port.onDisconnect.addListener(() => {
      if (state.port !== port) return; // we closed it ourselves
      state.port = null;
      state.fallbackInflight.clear();
      // Safari unloaded the background page (or it crashed): reconnect and
      // re-send; chunks it already finished replay from the cache.
      if (state.job && !state.job.finished) scheduleReconnect();
    });
    state.port = port;
    return port;
  }

  function postToPort(msg) {
    const port = openPort();
    if (!port) return false;
    try { port.postMessage(msg); return true; } catch (e) { return false; }
  }

  // Restarts whatever the current mode needs from scratch. Results already
  // produced come back instantly from background.js's cache.
  function startPipeline() {
    stopJob();
    state.errorCode = null;
    state.errorHint = '';
    state.partialMissing = 0;
    resetItems(null);
    state.pipelineHeld = false;
    const mode = settings.mode;
    if (!state.urlMovieId) { state.status = 'idle'; return; }
    if (!settings.enabled) { state.status = 'off'; return; }
    if (waitingForAppPrefs()) {
      // Nothing mode-specific yet; resumeHeldPipeline() comes back here.
      state.pipelineHeld = true;
      state.status = state.activeTrackId || state.fallback ? 'fetching' : 'waiting-tracks';
      return;
    }
    if (state.fallback) {
      state.status = 'fallback';
      if (mode === 'netflix' && !state.noDataHintShown) {
        state.noDataHintShown = true;
        showNotice(TEXT.noData, NOTICE_MS + 2000);
      }
      return;
    }
    if (!state.cues.length) {
      state.status = state.activeTrackId ? 'fetching' : 'waiting-tracks';
      return;
    }
    if (mode === 'netflix') {
      // Both lines come straight from Netflix, each on its own timeline: no
      // background job at all.
      state.status = state.secondState === 'loading' ? 'fetching' : 'ready';
      maybeShowNoSecondHint();
      return;
    }
    const sourceLang = primaryLanguage();
    if (sourceLang && MS.sameLanguage(sourceLang, settings.targetLang)) {
      // The original subtitle is already in the target language: nothing to
      // translate or gloss, so no native call and no model load.
      state.status = 'passthrough';
      return;
    }
    if (state.secondState === 'loading' && !state.secondTimedOut) {
      // The official line is the reference for both AI modes; wait for it
      // (bounded by SECOND_TRACK_TIMEOUT_MS) so the first request has it.
      state.status = 'fetching';
      state.waitingForReference = true;
      return;
    }
    startJob(mode);
  }

  function startJob(kind) {
    const referenceLines = state.secondState === 'ready'
      ? MS.alignCues(state.cues, state.secondCues)
      : new Array(state.cues.length).fill(null);
    const msg = {
      type: 'job',
      kind: kind,
      movieId: state.urlMovieId,
      sourceLang: primaryLanguage(),
      targetLang: settings.targetLang,
      lines: state.cues.map((c) => c.text),
      referenceLines: referenceLines,
      starts: state.cues.map((c) => c.start),
      startIndex: currentCueIndex()
    };
    if (kind === 'annotate') msg.level = settings.annotateLevel;
    resetItems(kind);
    state.job = { kind: kind, msg: msg, finished: false };
    state.status = kind === 'translate' ? 'translating' : 'annotating';
    sendJob();
    // Separate and fire-and-forget, so a slow title lookup (up to 1.5 s)
    // never delays the first subtitles.
    fetchAndStoreEpisodeTitle(msg.movieId, msg.sourceLang, msg.targetLang);
  }

  function sendJob() {
    const job = state.job;
    if (!job || job.finished) return;
    // Resent jobs start where the viewer is now, not where they were.
    job.msg.startIndex = currentCueIndex();
    if (!postToPort(job.msg)) scheduleReconnect();
  }

  function scheduleReconnect() {
    if (state.reconnectTimer || !state.job) return;
    const attempt = state.reconnectAttempts++;
    if (attempt >= 5) {
      // The extension was probably reloaded or updated under this page.
      failJob('native-unavailable');
      return;
    }
    state.reconnectTimer = setTimeout(() => {
      state.reconnectTimer = null;
      sendJob();
    }, 1000 * Math.pow(2, attempt));
  }

  function currentCueIndex() {
    const video = getVideo();
    return video ? MS.cueIndexAtOrAfter(state.cues, video.currentTime) : 0;
  }

  function failJob(code) {
    if (state.job) state.job.finished = true;
    state.status = 'error';
    state.errorCode = code || 'provider-error';
    state.errorHint = 'MultiSub：' + MS.errorText(state.errorCode);
    state.lastRenderedKey = null;
    clearRetryTimer();
    if (AUTO_RETRY_CODES.has(state.errorCode)) {
      const failedCode = state.errorCode;
      scheduleRetry(() => state.status === 'error' && state.errorCode === failedCode);
    }
  }

  // Restarts the pipeline after AUTO_RETRY_MS while `stillWanted()` holds,
  // at most AUTO_RETRY_MAX times per episode (reset by a complete 'done').
  // Finished chunks replay from background.js's cache, so a retry only
  // redoes what's missing. Returns whether a retry was scheduled.
  function scheduleRetry(stillWanted) {
    clearRetryTimer();
    if (state.autoRetries >= AUTO_RETRY_MAX) return false;
    const job = state.job;
    state.retryTimer = setTimeout(() => {
      state.retryTimer = null;
      if (state.job !== job || !stillWanted()) return;
      state.autoRetries++;
      startPipeline();
    }, AUTO_RETRY_MS);
    return true;
  }

  function onPortMessage(msg) {
    if (msg.type === 'heartbeat') { state.reconnectAttempts = 0; return; }
    if (msg.type === 'line-result') { onLineResult(msg); return; }
    const job = state.job;
    if (!job || msg.kind !== job.kind) return;
    state.reconnectAttempts = 0;
    if (msg.type === 'progress') {
      applyProgress(msg.start, msg.items);
    } else if (msg.type === 'done') {
      job.finished = true;
      state.status = 'done';
      if (msg.partial) {
        // Some chunks failed but the rest is on screen: a short notice, not
        // the permanent error hint, and a quiet retry for the missing lines.
        state.partialMissing = Number(msg.missing) || 0;
        const retrying = scheduleRetry(() => state.status === 'done');
        showNotice(TEXT.partial(job.kind, retrying), NOTICE_MS);
      } else {
        state.partialMissing = 0;
        state.autoRetries = 0;
      }
    } else if (msg.type === 'superseded') {
      // Another tab started a different job for the same episode and
      // language, which replaced this one. Stop waiting for it; later, ask
      // again and replay whatever that job has cached by then.
      job.finished = true;
      scheduleRetry(() => true);
    } else if (msg.type === 'error') {
      dbg('job error', msg.code, msg.detail);
      failJob(msg.code);
    }
  }

  function cleanAnnotations(list) {
    if (!Array.isArray(list)) return [];
    return list.filter((a) => a && typeof a.term === 'string' && typeof a.gloss === 'string' &&
      a.term.trim() && a.gloss.trim());
  }

  // Only annotations whose term occurs in the line: one that can't be
  // placed must not use up its term's GLOSS_REPEAT_LIMIT budget either.
  function placeableAnnotations(list, text) {
    return cleanAnnotations(list).filter((a) => !!MS.findTerm(text, a.term));
  }

  function applyProgress(start, items) {
    if (!Array.isArray(items)) return;
    const annotate = state.itemsKind === 'annotate';
    for (let i = 0; i < items.length; i++) {
      const idx = start + i;
      if (idx < 0 || idx >= state.items.length || items[i] == null) continue;
      if (state.items[idx] == null) state.readyCount++;
      state.items[idx] = annotate
        ? placeableAnnotations(items[i], (state.cues[idx] && state.cues[idx].text) || '')
        : String(items[i]);
    }
    if (annotate) state.glossPlanDirty = true;
    state.lastRenderedKey = null;
  }

  // Which annotations each cue may show: a term (lowercased) is glossed only
  // on its first GLOSS_REPEAT_LIMIT annotated cues in cue order. Rebuilt
  // lazily after progress, since chunks arrive out of order.
  function glossPlan() {
    if (state.glossPlan && !state.glossPlanDirty) return state.glossPlan;
    const plan = new Array(state.items.length).fill(null);
    const counts = new Map();
    for (let i = 0; i < state.items.length; i++) {
      const list = state.items[i];
      if (!Array.isArray(list) || !list.length) continue;
      const allowed = [];
      const seenHere = new Set();
      for (const a of list) {
        const key = a.term.trim().toLowerCase();
        if (seenHere.has(key)) continue;
        seenHere.add(key);
        const count = (counts.get(key) || 0) + 1;
        counts.set(key, count);
        if (count <= GLOSS_REPEAT_LIMIT) allowed.push(a);
      }
      plan[i] = allowed;
    }
    state.glossPlan = plan;
    state.glossPlanDirty = false;
    state.segMemo = null;
    return plan;
  }

  function annotatedSegments(text, allowed) {
    const memo = state.segMemo;
    if (memo && memo.text === text && memo.allowed === allowed) return memo.segments;
    const segments = allowed && allowed.length ? MS.matchAnnotations(text, allowed) : null;
    state.segMemo = { text: text, allowed: allowed, segments: segments };
    return segments;
  }

  function maybeShowNoSecondHint() {
    if (settings.mode !== 'netflix' || state.secondState !== 'none' || state.noSecondHintShown) return;
    if (waitingForAppPrefs()) return; // the mode may not be netflix after all
    state.noSecondHintShown = true;
    showNotice(TEXT.noSecond(settings.targetLang), NOTICE_MS);
  }

  function showNotice(text, ms) {
    state.notice = { text: text, until: Date.now() + (ms || NOTICE_MS) };
    state.lastRenderedKey = null;
  }

  function currentHint() {
    if (state.errorHint) return state.errorHint;
    if (state.notice && Date.now() < state.notice.until) return state.notice.text;
    return '';
  }

  // Keep Safari from unloading the background page mid-job.
  setInterval(() => {
    const job = state.job;
    if (job && !job.finished && state.port) {
      try { state.port.postMessage({ type: 'keepalive' }); } catch (e) { /* onDisconnect handles it */ }
    }
  }, KEEPALIVE_MS);

  // ===========================================================================
  // 6. DOM fallback
  // ===========================================================================
  function enableFallback(reason, detail) {
    dbg('falling back to DOM subtitles:', reason, detail || '');
    if (state.trackPollTimer) { clearInterval(state.trackPollTimer); state.trackPollTimer = null; }
    clearPrimaryRetry();
    state.fallback = true;
    state.fallbackReason = reason;
    startPipeline();
  }

  function clearFallbackResults() {
    state.fallbackCache.clear();
    state.fallbackInflight.clear();
    state.fallbackGlossCounts.clear();
    state.fallbackGlossPlan.clear();
    state.fallbackPausedUntil = 0;
  }

  // Netflix renders each subtitle line in its own container with <br>s in
  // between; textContent would glue the lines together, and innerText loses
  // them while the element is hidden in merged mode, so walk the nodes.
  function readDomSubtitle() {
    const container = document.querySelector('.player-timedtext');
    if (!container) return '';
    let out = '';
    (function walk(node) {
      for (const child of node.childNodes) {
        if (child.nodeType === 3) out += child.nodeValue;
        else if (child.nodeName === 'BR') out += '\n';
        else if (child.nodeType === 1) {
          const before = out.length;
          walk(child);
          if (out.length > before && child.classList.contains('player-timedtext-text-container')) out += '\n';
        }
      }
    })(container);
    return out.replace(/[ \t]*\n[ \t]*/g, '\n').replace(/\n{2,}/g, '\n').trim();
  }

  function requestLine(kind, text) {
    const key = kind + '\u0000' + text;
    if (state.fallbackCache.has(key) || state.fallbackInflight.has(key)) return;
    if (Date.now() < state.fallbackPausedUntil) return;
    // The local model works one line at a time (and a burst of requests on
    // a cold start would each load it). The tick asks again for whatever
    // line is on screen once the one in flight returns.
    const cloud = !!(state.engine && state.engine.active === 'cloud');
    if (!cloud && state.fallbackInflight.size) return;
    state.fallbackInflight.add(key);
    const msg = { type: 'line', kind: kind, text: text, targetLang: settings.targetLang };
    if (kind === 'annotate') {
      msg.level = settings.annotateLevel;
      // Optional extra: the language Netflix's player reported, if any.
      msg.sourceLang = state.netflixActiveBcp47 || '';
    }
    if (!postToPort(msg)) state.fallbackInflight.delete(key);
  }

  function onLineResult(msg) {
    const kind = msg.kind === 'annotate' ? 'annotate' : 'translate';
    const key = kind + '\u0000' + msg.text;
    state.fallbackInflight.delete(key);
    // background.js skipped a line that was no longer the newest one waiting.
    if (msg.dropped) return;
    if (msg.code) {
      // Don't hammer a failing engine every 100 ms tick.
      state.fallbackPausedUntil = Date.now() + FALLBACK_ERROR_PAUSE_MS;
      state.errorCode = msg.code;
      state.errorHint = 'MultiSub：' + MS.errorText(msg.code);
      state.lastRenderedKey = null;
      return;
    }
    if (state.errorHint && state.status === 'fallback') { state.errorHint = ''; state.errorCode = null; }
    state.fallbackCache.set(key, kind === 'annotate'
      ? placeableAnnotations(msg.result, String(msg.text))
      : String(msg.result == null ? '' : msg.result));
    while (state.fallbackCache.size > FALLBACK_CACHE_MAX) {
      state.fallbackCache.delete(state.fallbackCache.keys().next().value);
    }
    state.lastRenderedKey = null;
  }

  // Same repeat limit as glossPlan(), counted in the order lines show up.
  function fallbackAllowed(text, list) {
    if (state.fallbackGlossPlan.has(text)) return state.fallbackGlossPlan.get(text);
    const allowed = [];
    const seenHere = new Set();
    for (const a of list) {
      const key = a.term.trim().toLowerCase();
      if (seenHere.has(key)) continue;
      seenHere.add(key);
      const count = (state.fallbackGlossCounts.get(key) || 0) + 1;
      state.fallbackGlossCounts.set(key, count);
      if (count <= GLOSS_REPEAT_LIMIT) allowed.push(a);
    }
    state.fallbackGlossPlan.set(text, allowed);
    return allowed;
  }

  // ===========================================================================
  // 7. Overlay rendering
  // ===========================================================================
  let overlay = null;
  let overlayOriginal = null;
  let overlayText = null;
  let overlayHint = null;

  function buildOverlay() {
    overlay = document.createElement('div');
    overlay.id = 'multisub-overlay';
    // The upper line goes first in DOM order so #multisub-text stays the
    // bottom-most child: its position is what bottomOffset and dragging
    // calibrate against, in every layout.
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

  function hexToRgba(hex, opacity) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
    if (!m) return 'rgba(0, 0, 0, ' + opacity + ')';
    const n = parseInt(m[1], 16);
    return 'rgba(' + ((n >> 16) & 255) + ', ' + ((n >> 8) & 255) + ', ' + (n & 255) + ', ' + opacity + ')';
  }

  // An outline as a 4-direction text-shadow (there's no reliable
  // cross-engine text-stroke), or 'none' when switched off. No blur: blurred
  // shadows smear small glyphs such as the glosses.
  function outlineShadow(enabled, color) {
    if (!enabled) return 'none';
    return ['-1px -1px 0 ', '1px -1px 0 ', '-1px 1px 0 ', '1px 1px 0 '].map((o) => o + color).join(', ');
  }

  function applySettingsToOverlay() {
    updateNativeHidden();
    if (!overlay) return;
    overlay.style.setProperty('--multisub-bottom', settings.bottomOffset + '%');
    overlay.style.setProperty('--multisub-font-scale', String(settings.fontScale));
    const st = Object.assign({}, MS.DEFAULT_STYLES, settings.styles || {});
    overlay.style.setProperty('--multisub-color', st.textColor);
    overlay.style.setProperty('--multisub-bg', hexToRgba(st.backgroundColor, st.backgroundOpacity));
    overlay.style.setProperty('--multisub-font', st.fontFamily);
    overlay.style.setProperty('--multisub-line-height', String(st.lineHeight));
    overlay.style.setProperty('--multisub-outline', outlineShadow(st.outlineEnabled, st.outlineColor));
    overlay.style.setProperty('--multisub-font-weight', st.boldEnabled ? 'bold' : 'normal');
    overlay.style.display = settings.enabled ? '' : 'none';
    state.lastRenderedKey = null;
  }

  // Whether the line Netflix itself draws is our primary track, so the
  // non-merged layout can leave the first line to Netflix. It isn't when
  // Netflix's subtitles are off (or only show forced narratives), or when
  // they're in the target language (choosePrimaryTrack then picks another
  // track) or the viewer picked a different source track in the popup.
  function netflixDrawsPrimary() {
    if (state.fallback) return true; // the DOM fallback reads exactly what Netflix draws
    // No report from Netflix's player (its private API changed): assume it
    // shows what we picked, as before these reports existed.
    if (!state.activeTrackReported) return true;
    const primary = primaryTrack();
    return !!(primary && state.netflixActiveBcp47 && !state.netflixActiveForced &&
      MS.sameLanguage(primary.language, state.netflixActiveBcp47));
  }

  // Merged layout: Netflix's own subtitle element is hidden and we draw both
  // lines. Annotate always replaces the original line, so it's always merged.
  // With 雙語合併顯示 off, Netflix draws the first line, which only works
  // while it draws the primary track; otherwise we draw both lines ourselves
  // rather than show the target language twice or the original not at all.
  function mergedLayout() {
    return settings.mode === 'annotate' || !!settings.mergedMode || !netflixDrawsPrimary();
  }

  // Netflix's subtitles are hidden only while we have something to draw in
  // their place: cues of our own, or (outside netflix mode) the DOM-fallback
  // text we mirror. Hiding them earlier would leave the viewer with no
  // subtitles at all while tracks load, or for good if capture fails. Same
  // while waiting for the app's preferences, when we draw nothing.
  function shouldHideNative() {
    if (!settings.enabled || !state.urlMovieId || waitingForAppPrefs()) return false;
    const canDraw = state.fallback ? settings.mode !== 'netflix' : state.cues.length > 0;
    return canDraw && mergedLayout();
  }

  function updateNativeHidden() {
    const hide = shouldHideNative();
    if (hide === state.nativeHidden) return;
    state.nativeHidden = hide;
    document.documentElement.classList.toggle('multisub-native-hidden', hide);
  }

  function overlayContainer(video) {
    return video.closest('.watch-video') || video.parentElement;
  }

  function ensureOverlayAttached(video) {
    if (!overlay) buildOverlay();
    const container = overlayContainer(video);
    if (!container) return null;
    if (overlay.parentElement !== container) {
      if (getComputedStyle(container).position === 'static') container.style.position = 'relative';
      container.appendChild(overlay);
    }
    return container;
  }

  // Each \n-separated line becomes its own .ms-line child instead of one text
  // node relying on white-space: pre-wrap, which lets overlay.css keep the
  // background box snug to the glyphs at any line height.
  function newLine(container) {
    const div = document.createElement('div');
    div.className = 'ms-line';
    container.appendChild(div);
    return div;
  }

  function setLines(container, text) {
    container.textContent = '';
    if (!text) return;
    for (const line of text.split('\n')) newLine(container).textContent = line;
  }

  // Original line with <span class="ms-term">term</span><span class="ms-gloss">gloss</span>.
  function setAnnotatedLines(container, segments) {
    container.textContent = '';
    let line = newLine(container);
    for (const seg of segments) {
      if (seg.gloss == null) {
        seg.text.split('\n').forEach((part, i) => {
          if (i > 0) line = newLine(container);
          if (part) line.appendChild(document.createTextNode(part));
        });
        continue;
      }
      const term = document.createElement('span');
      term.className = 'ms-term';
      // A phrase broken across two cue lines stays together with its gloss.
      term.textContent = seg.text.replace(/\s*\n\s*/g, ' ');
      const gloss = document.createElement('span');
      gloss.className = 'ms-gloss';
      gloss.textContent = seg.gloss;
      line.appendChild(term);
      line.appendChild(gloss);
    }
  }

  // frame: { top, bottom, segments? } — `top` is the upper line (the original
  // in merged layouts), `bottom` the lower one; `segments` renders `bottom`
  // with glosses.
  function render(frame) {
    if (!overlay) return;
    const hint = currentHint();
    const segKey = frame.segments ? JSON.stringify(frame.segments) : '';
    const key = frame.top + '\u0001' + frame.bottom + '\u0001' + segKey + '\u0001' + hint;
    if (state.lastRenderedKey === key) return;
    state.lastRenderedKey = key;
    setLines(overlayOriginal, frame.top);
    if (frame.segments) setAnnotatedLines(overlayText, frame.segments);
    else setLines(overlayText, frame.bottom);
    // The stylesheet sets display:none on both lines; clearing the inline
    // style ('') would fall back to that, so set 'flex' explicitly.
    overlayOriginal.style.display = frame.top ? 'flex' : 'none';
    overlayText.style.display = frame.bottom ? 'flex' : 'none';
    overlayHint.textContent = hint;
    overlayHint.style.display = hint ? 'block' : 'none';
  }

  const EMPTY_FRAME = { top: '', bottom: '' };

  function cueFrame(t) {
    const mode = settings.mode;
    const merged = mergedLayout();
    const idx = MS.findCueIndex(state.cues, t);
    const original = idx >= 0 ? state.cues[idx].text || '' : '';
    if (mode === 'netflix') {
      // Separate timelines: Netflix often splits lines differently per
      // language, and aligning would drop or merge some of them.
      const j = state.secondState === 'ready' ? MS.findCueIndex(state.secondCues, t) : -1;
      return { top: merged ? original : '', bottom: j >= 0 ? state.secondCues[j].text || '' : '' };
    }
    if (state.status === 'passthrough') return { top: '', bottom: merged ? original : '' };
    if (mode === 'translate') {
      const tr = idx >= 0 && typeof state.items[idx] === 'string' ? state.items[idx] : '';
      return { top: merged ? original : '', bottom: tr };
    }
    // annotate: a cue whose annotations aren't ready shows the plain line.
    if (idx < 0) return EMPTY_FRAME;
    const allowed = Array.isArray(state.items[idx]) ? glossPlan()[idx] : null;
    return { top: '', bottom: original, segments: annotatedSegments(original, allowed) };
  }

  function fallbackFrame() {
    const mode = settings.mode;
    if (mode === 'netflix') return EMPTY_FRAME; // Netflix's own subtitles stay visible
    const original = readDomSubtitle();
    if (!original) return EMPTY_FRAME;
    const merged = mergedLayout();
    const key = mode + '\u0000' + original;
    if (!state.fallbackCache.has(key)) requestLine(mode, original);
    const result = state.fallbackCache.get(key);
    if (mode === 'translate') {
      return { top: merged ? original : '', bottom: typeof result === 'string' ? result : '' };
    }
    const allowed = Array.isArray(result) ? fallbackAllowed(original, result) : null;
    return { top: '', bottom: original, segments: annotatedSegments(original, allowed) };
  }

  // --- Drag-to-position. Only reachable while drag mode is on, since
  // #multisub-text is pointer-events:none otherwise (overlay.css's
  // .multisub-drag-enabled); the dragModeEnabled checks are defensive.
  let dragState = null;

  function updateDragAffordance() {
    if (overlay) overlay.classList.toggle('multisub-drag-enabled', state.dragModeEnabled);
  }

  function onDragPointerDown(ev) {
    if (!state.dragModeEnabled) return;
    const container = overlay.parentElement;
    if (!container) return;
    const containerHeight = container.getBoundingClientRect().height;
    if (!containerHeight) return; // avoid a NaN% offset before layout
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
    // Moving the pointer down brings the subtitle closer to the bottom edge,
    // i.e. a smaller bottomOffset, hence the minus sign.
    const deltaPercent = ((ev.clientY - dragState.startY) / dragState.containerHeight) * 100;
    const next = Math.max(DRAG_MIN_OFFSET, Math.min(DRAG_MAX_OFFSET, Math.round(dragState.startOffset - deltaPercent)));
    dragState.currentValue = next;
    overlay.style.setProperty('--multisub-bottom', next + '%');
  }

  function onDragPointerUp(ev) {
    if (!dragState || ev.pointerId !== dragState.pointerId) return;
    const finalValue = dragState.currentValue;
    dragState = null;
    // Write storage once, on release, not on every pointermove.
    if (finalValue !== settings.bottomOffset) {
      settings = Object.assign({}, settings, { bottomOffset: finalValue });
      api.storage.local.set({ settings: MS.storedSettings(settings) }).catch(() => {});
    }
  }

  // ===========================================================================
  // 8. One-time toast
  // ===========================================================================
  // Shown once per install, on the first watch page that plays: MultiSub is
  // on, which mode and second language it uses, and where to change them.
  // Nothing has to be chosen before subtitles show up (the mode defaults to
  // MS.DEFAULT_MODE), so this only informs and never blocks: it sits in the
  // player's top-right corner, leaves by itself after WELCOME_TOAST_MS, and
  // everything but its close button is click-through to the player. It
  // lives in the same container as #multisub-overlay, so it stays visible in
  // fullscreen, and in a shadow root so Netflix's styles can't reach it.

  const WELCOME_TOAST_MS = 8000;
  // Matches the .leaving transition below.
  const WELCOME_TOAST_FADE_MS = 300;
  // storage.local key, outside `settings` (and outside the 'ms:' cache pool
  // background.js prunes).
  const WELCOME_SHOWN_KEY = 'welcomeShown';

  const TOAST_CSS = [
    ':host { all: initial; }',
    '.toast { position: relative; box-sizing: border-box; width: max-content; max-width: min(340px, calc(100vw - 32px));',
    '  padding: 12px 38px 12px 14px; border-radius: 12px; color: #f5f5f7; pointer-events: none;',
    '  background: rgba(22, 22, 26, 0.86);',
    '  -webkit-backdrop-filter: blur(18px) saturate(140%); backdrop-filter: blur(18px) saturate(140%);',
    '  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba(255, 255, 255, 0.08);',
    '  font: 13px/1.45 -apple-system, BlinkMacSystemFont, "PingFang TC", system-ui, sans-serif;',
    '  -webkit-font-smoothing: antialiased;',
    '  animation: ms-toast-in 0.2s ease-out; transition: opacity 0.3s ease, transform 0.3s ease; }',
    '.toast.leaving { opacity: 0; transform: translateY(-6px); }',
    '.title { margin: 0 0 4px; font-size: 14px; font-weight: 600; }',
    '.body { margin: 0; color: rgba(245, 245, 247, 0.82); }',
    '.close { pointer-events: auto; position: absolute; top: 6px; right: 6px; width: 26px; height: 26px;',
    '  margin: 0; padding: 0; border: 0; border-radius: 7px; background: none; cursor: pointer;',
    '  font: 18px/26px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; color: rgba(245, 245, 247, 0.7); }',
    '.close:hover { color: #fff; background: rgba(255, 255, 255, 0.1); }',
    '.close:focus-visible { outline: 2px solid #ff6b72; outline-offset: 1px; }',
    '@keyframes ms-toast-in { from { opacity: 0; transform: translateY(-6px); } to { opacity: 1; transform: none; } }',
    '@media (prefers-reduced-motion: reduce) {',
    '  .toast { animation: none; transition: none; }',
    '  .toast.leaving { transform: none; }',
    '}'
  ].join('\n');

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  // Unreadable storage counts as seen: if the flag can't be read it likely
  // can't be written either, and the toast must not come back on every page.
  api.storage.local.get(WELCOME_SHOWN_KEY)
    .then((res) => { toast.seen = !!(res && res[WELCOME_SHOWN_KEY]); })
    .catch(() => { toast.seen = true; });

  function buildToast() {
    const host = document.createElement('div');
    host.id = 'multisub-toast';
    host.style.cssText = 'position:absolute;top:max(64px,8%);right:3%;z-index:2147483001;pointer-events:none;';
    const root = host.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = TOAST_CSS;
    root.appendChild(style);
    const card = el('div', 'toast');
    card.setAttribute('role', 'status');
    card.setAttribute('aria-live', 'polite');
    card.appendChild(el('p', 'title', TEXT.toastTitle));
    card.appendChild(el('p', 'body'));
    card.appendChild(el('p', 'body hint', TEXT.toastHint));
    const close = el('button', 'close', '×');
    close.type = 'button';
    close.setAttribute('aria-label', TEXT.toastClose);
    close.addEventListener('click', hideToast);
    card.appendChild(close);
    root.appendChild(card);
    // The close button is the only thing that takes pointer events; keep
    // its clicks and keys from reaching Netflix's player (play/pause on
    // click, space, arrow-key seeking).
    for (const type of ['click', 'dblclick', 'pointerdown', 'pointerup', 'mousedown', 'mouseup', 'keydown', 'keyup', 'keypress']) {
      host.addEventListener(type, (e) => e.stopPropagation());
    }
    toast.host = host;
    toast.root = root;
    renderToastText();
  }

  function renderToastText() {
    const body = toast.root && toast.root.querySelector('.body');
    if (body) body.textContent = TEXT.toastBody(settings.mode, settings.targetLang);
  }

  // Waits for the startup ping (so a mode or language chosen in the app has
  // been adopted) and for the video to play, so the toast isn't spent on a
  // loading spinner.
  function maybeShowToast(container, video) {
    if (toast.seen !== false || !settings.enabled || !state.startupPingDone) return;
    if (!container || video.paused) return;
    toast.seen = true;
    api.storage.local.set({ [WELCOME_SHOWN_KEY]: true }).catch(() => {});
    buildToast();
    container.appendChild(toast.host);
    toast.timer = setTimeout(hideToast, WELCOME_TOAST_MS);
  }

  // Fades out (instantly under prefers-reduced-motion, see TOAST_CSS), then
  // removes it.
  function hideToast() {
    if (!toast.host) return;
    clearTimeout(toast.timer);
    const card = toast.root.querySelector('.toast');
    if (card) card.classList.add('leaving');
    toast.timer = setTimeout(removeToast, WELCOME_TOAST_FADE_MS);
  }

  function removeToast() {
    clearTimeout(toast.timer);
    toast.timer = null;
    if (toast.host) toast.host.remove();
    toast.host = null;
    toast.root = null;
  }

  // Every tick: show it once the conditions hold, and follow the player if
  // Netflix replaces the container (e.g. entering fullscreen).
  function updateToast(container, video) {
    if (!toast.host) { maybeShowToast(container, video); return; }
    if (container && toast.host.parentElement !== container) container.appendChild(toast.host);
  }

  // ===========================================================================
  // 9. Sync loop
  // ===========================================================================

  // The viewer seeked while a job is running: ask background.js to work on
  // the chunks from here first.
  function detectSeek(t) {
    const last = state.lastVideoTime;
    state.lastVideoTime = t;
    if (last == null || Math.abs(t - last) <= SEEK_JUMP_SEC) return;
    const job = state.job;
    if (!job || job.finished || !state.port) return;
    dbg('seek detected', last, '->', t);
    try {
      state.port.postMessage({
        type: 'prioritize', kind: job.kind, movieId: job.msg.movieId,
        index: MS.cueIndexAtOrAfter(state.cues, t)
      });
    } catch (e) { /* onDisconnect re-sends the job from the current position */ }
  }

  function tick() {
    checkUrl();
    if (!state.urlMovieId) return; // not on a watch page
    const video = getVideo();
    if (!video) return;
    const container = ensureOverlayAttached(video);
    updateNativeHidden();
    updateToast(container, video);
    // Nothing of ours until the mode is known (see waitingForAppPrefs);
    // Netflix's own subtitles stay up meanwhile.
    if (!settings.enabled || waitingForAppPrefs()) {
      render(EMPTY_FRAME);
      return;
    }
    const t = video.currentTime;
    detectSeek(t);
    render(state.fallback ? fallbackFrame() : cueFrame(t));
  }

  setInterval(tick, 100);

  // ===========================================================================
  // 10. Navigation (Netflix is a single-page app)
  // ===========================================================================
  function currentUrlMovieId() {
    const m = location.pathname.match(/^\/watch\/(\d+)/);
    return m ? m[1] : null;
  }

  function checkUrl() {
    const id = currentUrlMovieId();
    if (id !== state.urlMovieId) resetForMovie(id);
  }

  function resetForMovie(movieId) {
    dbg('resetForMovie ->', movieId);
    stopJob();
    state.urlMovieId = movieId;
    state.tracks = [];
    state.tracksAt = 0;
    state.activeTrackId = null;
    // A track picked in the popup was for that episode: track ids carry an
    // index, so the same id can mean another track (or none) in the next
    // one. Follow Netflix's player again.
    state.sourceMode = 'auto';
    state.manualTrackId = null;
    state.activeTrackReported = false;
    state.netflixActiveBcp47 = null;
    state.netflixActiveForced = false;
    state.netflixAudioBcp47 = null;
    if (state.selectTimer) { clearTimeout(state.selectTimer); state.selectTimer = null; }
    state.cues = [];
    state.primaryRetries = 0;
    clearPrimaryRetry();
    state.fallbackReason = null;
    state.fallbackRecoveries = 0;
    state.partialMissing = 0;
    clearSecondTimer();
    state.secondTrackId = null;
    state.secondState = 'unknown';
    state.secondCues = [];
    state.secondTimedOut = false;
    resetItems(null);
    state.errorCode = null;
    state.errorHint = '';
    state.autoRetries = 0;
    state.fallback = false;
    clearFallbackResults();
    state.notice = null;
    state.noSecondHintShown = false;
    state.noDataHintShown = false;
    state.lastVideoTime = null;
    state.status = movieId ? 'waiting-tracks' : 'idle';
    if (state.trackPollTimer) { clearInterval(state.trackPollTimer); state.trackPollTimer = null; }
    updateNativeHidden();
    if (!movieId) {
      removeToast();
      return;
    }
    // The manifest may already have been captured, or not have arrived yet:
    // ask the page script for tracks until they show up.
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

  // ===========================================================================
  // 11. Popup messaging and the vocabulary hand-off
  // ===========================================================================

  // Asks inject.js for show/episode/season metadata via Netflix's private
  // player API (see getVideoTitle there). Resolves to {seriesTitle,
  // episodeTitle, seasonNumber, episodeNumber}, or null on timeout or any
  // failure: a best-effort lookup, never worth blocking anything over.
  function requestEpisodeTitle(movieId) {
    return new Promise((resolve) => {
      let settled = false;
      // `waiter`, not `resolve`, is what goes into pendingTitleRequests and
      // must be the very reference removed on timeout; otherwise the dead
      // entry stays in the map and a later request attaches to it instead of
      // sending a fresh 'get-title'.
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
      // A lookup for this movieId already in flight: wait on that one.
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

  // Last resort when the private-API lookup returns null. document.title is
  // not reliable during playback (it is usually just "Netflix"), so strip a
  // trailing "- Netflix"/"| Netflix" and give up to the raw movieId if
  // nothing useful is left. Same shape as requestEpisodeTitle's result.
  function extractEpisodeTitleFallback() {
    let title = (document.title || '').trim();
    title = title.replace(/\s*[-|]\s*Netflix\s*$/i, '').trim();
    if (!title || /^netflix$/i.test(title)) title = state.urlMovieId;
    return { seriesTitle: title, episodeTitle: null, seasonNumber: null, episodeNumber: null };
  }

  // Attaches series/episode titles to this episode's cache entry for the
  // app's cache-management tab (real titles, grouped by series).
  async function fetchAndStoreEpisodeTitle(movieId, sourceLang, targetLang) {
    const titleInfo = (await requestEpisodeTitle(movieId)) || extractEpisodeTitleFallback();
    if (!state.port || state.urlMovieId !== movieId) return;
    try {
      state.port.postMessage({
        type: 'episode-title',
        movieId: movieId,
        sourceLang: sourceLang,
        targetLang: targetLang,
        seriesTitle: titleInfo.seriesTitle || movieId,
        episodeTitle: titleInfo.episodeTitle,
        seasonNumber: titleInfo.seasonNumber
      });
    } catch (e) { /* port gone; the cache entry just won't have a title yet */ }
  }

  // Packages this episode's transcript for the app's vocabulary feature
  // (native `save-transcript`, then `open-app` on the vocabulary tab). Both
  // native calls go through background.js; content scripts have no native
  // messaging of their own.
  async function organizeVocab() {
    if (!state.urlMovieId || !state.cues.length) return { ok: false, error: 'no-episode' };
    const sourceLang = primaryLanguage();
    // Gated on the track's language tag, not on detecting the text's
    // language. The popup disables the button for non-English tracks from the
    // same get-status data; this repeats the check in case the popup was left
    // open across a track switch.
    if (MS.normalizeBcp47(sourceLang) !== 'en') return { ok: false, error: 'non-english' };
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

  function secondaryTrackFound() {
    if (state.secondState === 'ready') return true;
    if (state.secondState === 'none') return false;
    return null; // unknown, loading or failed to load
  }

  api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (!msg) return false;
    if (msg.type === 'get-status') {
      sendResponse({
        onWatchPage: !!state.urlMovieId,
        movieId: state.urlMovieId,
        mode: settings.mode,
        tracks: state.tracks,
        activeTrackId: state.activeTrackId,
        sourceMode: state.sourceMode,
        status: state.status,
        translatedCount: state.readyCount,
        totalCues: state.cues.length,
        partialMissing: state.partialMissing,
        errorCode: state.errorCode,
        errorHint: state.errorHint,
        fallback: state.fallback,
        secondaryTrackFound: secondaryTrackFound(),
        secondState: state.secondState,
        engineActive: state.engine ? state.engine.active || null : null,
        jobKind: state.job ? state.job.kind : null,
        dragMode: state.dragModeEnabled
      });
    } else if (msg.type === 'set-track') {
      state.sourceMode = 'manual';
      state.manualTrackId = msg.trackId;
      selectTracks();
      sendResponse({ ok: true });
    } else if (msg.type === 'set-track-auto') {
      state.sourceMode = 'auto';
      state.manualTrackId = null;
      selectTracks();
      sendResponse({ ok: true });
    } else if (msg.type === 'set-drag-mode') {
      state.dragModeEnabled = !!msg.enabled;
      updateDragAffordance();
      sendResponse({ ok: true });
    } else if (msg.type === 'engine-changed') {
      // The popup just saved and tested an engine: refresh our view of it and
      // retry a job that failed for lack of one.
      pingNative().then(() => {
        if (state.status === 'error' && ENGINE_FIXABLE_CODES.has(state.errorCode)) startPipeline();
      });
      sendResponse({ ok: true });
    } else if (msg.type === 'organize-vocab') {
      organizeVocab().then(sendResponse);
      return true; // async response
    }
    return false;
  });
})();

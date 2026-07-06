// Background script: translation pipeline between content scripts and the
// native macOS host app (which runs the local Gemma model).
//
// - Batches episode subtitles into native-messaging requests.
// - Caches finished (and partial) translations in storage.local, keyed by
//   movieId + target language + source track language, so re-watching costs
//   nothing and interrupted translations resume where they stopped.
'use strict';

const api = typeof browser !== 'undefined' ? browser : chrome;

// Debug logging for the T3 glossary pipeline. Set to true, reload the
// extension, and check the *background page's* Web Inspector console
// (Safari → Develop → Web Extension Background Content → MultiSub — not the
// Netflix tab's console) to see what glossary was actually extracted.
const DEBUG = false;
function dbg() {
  if (!DEBUG) return;
  try { console.log.apply(console, ['[MultiSub][background]'].concat([].slice.call(arguments))); } catch (e) { /* ignore */ }
}

// Safari routes native messages to the containing app; the id is ignored.
const NATIVE_APP_ID = 'application.id';
const BATCH_SIZE = 12;
const MAX_CACHED_EPISODES = 40;
const CACHE_PREFIX = 'ms:';
// S4: bumped whenever a cached entry's stored shape changes in a way that
// isn't already caught by other checks (e.g. `translations.length ===
// lines.length`) — entries written under an older version are treated as a
// miss and swept by pruneCache, instead of risking a stale-shaped read.
const CACHE_SCHEMA_VERSION = 1;
// T3 stage 2: episode-wide name/term glossary, built from source/reference
// pairs in the background and cached. Shares CACHE_PREFIX's LRU pool.
const GLOSSARY_CACHE_PREFIX = CACHE_PREFIX + 'gl:';
const GLOSSARY_SEGMENT_SIZE = 40; // pairs per extract-glossary call
const GLOSSARY_MIN_PAIRS = 8; // below this, a glossary pass isn't worth the extra model calls
// 2026-07-06: series/episode/season metadata for a cache group, keyed the
// same way (movieId:targetLang:sourceLang) but under its own top-level
// prefix — deliberately NOT under CACHE_PREFIX ('ms:'), so it's invisible to
// pruneCache/evictOldestEntries' CACHE_PREFIX sweeps (a title-metadata
// object has no `.v` field, so pruneCache's stale-schema check would delete
// it on every single completed episode if it shared that prefix) and
// doesn't eat into MAX_CACHED_EPISODES' 40-entry budget. Written
// fire-and-forget by content.js (see its `fetchAndStoreEpisodeTitle`,
// unrelated to and never blocking translation), independently of the
// translation-cache entry's own read-modify-write cycle — keeping it a
// wholly separate key sidesteps the write-ordering race that would occur if
// both this and handleEpisode's batch loop wrote into the same object.
const TITLE_META_PREFIX = 'mstitle:';

// Bumped per (movieId,lang) whenever a new episode request arrives, so a
// stale pipeline (e.g. from a reconnected port) stops itself.
const generations = new Map();

// Small in-memory cache for the DOM-fallback line path.
const lineCache = new Map();
const LINE_CACHE_MAX = 500;

api.runtime.onConnect.addListener((port) => {
  if (port.name !== 'multisub') return;
  let disconnected = false;
  port.onDisconnect.addListener(() => { disconnected = true; });
  const isDead = () => disconnected;
  port.onMessage.addListener((msg) => {
    if (!msg) return;
    if (msg.type === 'episode') handleEpisode(port, msg, isDead);
    else if (msg.type === 'line') handleLine(port, msg, isDead);
    else if (msg.type === 'episode-title') handleEpisodeTitle(msg);
  });
});

function safePost(port, msg, isDead) {
  if (isDead()) return false;
  try { port.postMessage(msg); return true; } catch (e) { return false; }
}

async function sendNative(message) {
  return api.runtime.sendNativeMessage(NATIVE_APP_ID, message);
}

// M1: release the model's multi-GB footprint as soon as the popup toggle
// turns translation off, instead of leaving it resident until Safari
// eventually reclaims the extension process. Bumping every in-flight
// episode's generation makes handleEpisode's `stale()` checks stop the loop
// before its next batch (a batch already mid-flight when this fires still
// completes — cheap and harmless, its result stays cached).
api.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.settings) return;
  const wasEnabled = (changes.settings.oldValue || {}).enabled !== false;
  const isEnabled = (changes.settings.newValue || {}).enabled !== false;
  if (!(wasEnabled && !isEnabled)) return;
  dbg('settings.enabled -> false: cancelling in-progress episodes, unloading model');
  for (const key of generations.keys()) {
    generations.set(key, (generations.get(key) || 0) + 1);
  }
  sendNative({ action: 'unload' }).catch((e) => dbg('unload failed:', String(e && e.message || e)));
});

function classifyError(e) {
  const s = String(e && e.message || e).toLowerCase();
  if (s.includes('native') || s.includes('connect') || s.includes('port') || s.includes('messaging')) {
    return 'native-unavailable';
  }
  return s || 'unknown';
}

// 2026-07-06: records series/episode/season metadata for this episode's
// cache group, for the App's cache-management tab (real titles + grouping
// by series instead of a bare movieId — same feature V4 already does for
// the vocab flow). Fire-and-forget from content.js, independent of
// whether a cache entry exists yet or ever gets written — this is
// best-effort metadata, never required for translation itself.
async function handleEpisodeTitle({ movieId, targetLang, sourceLang, seriesTitle, episodeTitle, seasonNumber }) {
  if (!movieId || !seriesTitle) return;
  const key = TITLE_META_PREFIX + movieId + ':' + targetLang + ':' + (sourceLang || 'unknown');
  try {
    await api.storage.local.set({
      [key]: {
        seriesTitle: seriesTitle,
        episodeTitle: episodeTitle || null,
        seasonNumber: typeof seasonNumber === 'number' ? seasonNumber : null
      }
    });
  } catch (e) { dbg('handleEpisodeTitle failed:', String(e && e.message || e)); }
}

async function handleEpisode(port, { movieId, targetLang, sourceLang, lines, referenceLines }, isDead) {
  if (!Array.isArray(lines) || !lines.length) return;
  // Source track language is part of the cache key (T2): the same episode
  // watched with a different source subtitle track is a different transcript.
  const cacheKey = CACHE_PREFIX + movieId + ':' + targetLang + ':' + (sourceLang || 'unknown');
  const generation = (generations.get(cacheKey) || 0) + 1;
  generations.set(cacheKey, generation);
  const stale = () => generations.get(cacheKey) !== generation;

  let translations = new Array(lines.length).fill(null);
  try {
    const stored = (await api.storage.local.get(cacheKey))[cacheKey];
    if (stored && stored.v === CACHE_SCHEMA_VERSION
        && Array.isArray(stored.translations) && stored.translations.length === lines.length) {
      translations = stored.translations.slice();
    }
  } catch (e) { /* treat as no cache */ }

  // Replay whatever we already have.
  safePost(port, { type: 'progress', start: 0, translations: translations }, isDead);
  if (!translations.includes(null)) {
    safePost(port, { type: 'done', fromCache: true }, isDead);
    return;
  }

  // T3 stage 2: kick off glossary extraction in the background (not
  // awaited). Early batches keep using stage-1 per-line reference; once the
  // glossary resolves, later batches switch to it — cheaper per request and,
  // unlike per-line reference, it also helps lines with no directly-aligned
  // official cue (e.g. CC-only text).
  const glossaryState = { ready: false, glossary: null };
  resolveGlossary(movieId, targetLang, sourceLang, lines, referenceLines, stale)
    .then((g) => {
      glossaryState.ready = true;
      glossaryState.glossary = g;
      dbg('glossary ready for', cacheKey, '— terms:', g ? Object.keys(g).length : 0, g);
    })
    .catch((e) => {
      glossaryState.ready = true;
      glossaryState.glossary = null;
      dbg('glossary resolution failed for', cacheKey, String(e && e.message || e));
    });

  try {
    for (let i = 0; i < lines.length; i += BATCH_SIZE) {
      if (stale()) return;
      const end = Math.min(i + BATCH_SIZE, lines.length);
      if (!translations.slice(i, end).includes(null)) continue; // already cached
      const batch = lines.slice(i, end);
      const useGlossary = glossaryState.ready && glossaryState.glossary;
      // Pass this batch's aligned official-subtitle lines (stage 1) unless a
      // glossary (stage 2) is already available — sending both would just
      // burn extra tokens for no benefit.
      const batchReference = !useGlossary && Array.isArray(referenceLines) ? referenceLines.slice(i, end) : null;
      dbg('batch', i, '-', end, 'using', useGlossary ? 'glossary' : (batchReference ? 'stage-1 reference' : 'no reference'));
      const res = await sendNative({
        action: 'translate', lines: batch, targetLang: targetLang,
        reference: batchReference, glossary: useGlossary ? glossaryState.glossary : null
      });
      if (stale()) return;
      if (!res || res.ok !== true || !Array.isArray(res.translations)) {
        throw Object.assign(new Error(res && res.error || 'native-error'), { code: res && res.error });
      }
      for (let j = 0; j < batch.length; j++) {
        translations[i + j] = res.translations[j] != null ? String(res.translations[j]) : '';
      }
      await setCacheWithFallback(cacheKey, {
        v: CACHE_SCHEMA_VERSION, translations: translations, savedAt: Date.now(),
        targetLang: targetLang, sourceLang: sourceLang
      });
      safePost(port, { type: 'progress', start: i, translations: translations.slice(i, end) }, isDead);
      // Keep translating even if the tab's port went away — the cache still
      // benefits the next visit. But stop if a newer request superseded us.
    }
    await pruneCache();
    safePost(port, { type: 'done' }, isDead);
  } catch (e) {
    safePost(port, { type: 'error', code: e.code || classifyError(e), detail: String(e && e.message || e) }, isDead);
  }
}

// T3 stage 2: build (or reuse a cached) episode-wide glossary from the
// source/reference pairs already aligned in T2. Segmented into chunks of
// GLOSSARY_SEGMENT_SIZE pairs so each native call's prompt stays bounded;
// results are merged. A failed/empty segment just contributes nothing —
// one bad segment shouldn't sink the whole glossary.
async function resolveGlossary(movieId, targetLang, sourceLang, lines, referenceLines, stale) {
  if (!Array.isArray(referenceLines)) return null;
  const glossaryCacheKey = GLOSSARY_CACHE_PREFIX + movieId + ':' + targetLang + ':' + (sourceLang || 'unknown');
  try {
    const stored = (await api.storage.local.get(glossaryCacheKey))[glossaryCacheKey];
    if (stored && stored.v === CACHE_SCHEMA_VERSION && stored.glossary && Object.keys(stored.glossary).length) {
      dbg('glossary: cache hit', glossaryCacheKey, Object.keys(stored.glossary).length, 'terms');
      return stored.glossary;
    }
  } catch (e) { /* treat as no cache */ }

  const pairs = [];
  for (let i = 0; i < lines.length; i++) {
    if (referenceLines[i]) pairs.push({ source: lines[i], reference: referenceLines[i] });
  }
  dbg('glossary: aligned pairs available =', pairs.length, '(min required =', GLOSSARY_MIN_PAIRS + ')');
  if (pairs.length < GLOSSARY_MIN_PAIRS) return null;

  // Tally translations per term across all segments instead of letting the
  // last segment silently overwrite earlier ones — a single misaligned pair
  // (T2's alignment isn't perfect) shouldn't be able to clobber a term most
  // segments agreed on.
  const counts = {}; // term -> { translation -> occurrences }
  for (let i = 0; i < pairs.length; i += GLOSSARY_SEGMENT_SIZE) {
    if (stale()) return null;
    const segment = pairs.slice(i, i + GLOSSARY_SEGMENT_SIZE);
    try {
      const res = await sendNative({ action: 'extract-glossary', pairs: segment, targetLang: targetLang });
      dbg('glossary: segment', i, '-', i + segment.length, 'result=', res);
      if (res && res.ok === true && res.glossary && typeof res.glossary === 'object') {
        for (const term of Object.keys(res.glossary)) {
          const translation = res.glossary[term];
          if (!translation) continue;
          if (!counts[term]) counts[term] = {};
          counts[term][translation] = (counts[term][translation] || 0) + 1;
        }
      }
    } catch (e) { dbg('glossary: segment', i, 'threw', String(e && e.message || e)); }
  }

  // Extraction over a 40-pair segment occasionally shuffles term/translation
  // attributions (e.g. a name ending up paired with an unrelated location or
  // another character's name) — a single stray hit can still "win" a naive
  // majority vote if nothing else was extracted for that term. So a term is
  // only trusted when it has a clear winner: 2+ corroborating extractions
  // AND strictly more than the runner-up. Anything murkier is dropped —
  // better to fall back to the model's own judgment for that name than risk
  // injecting a wrong term episode-wide.
  const glossary = {};
  for (const term of Object.keys(counts)) {
    const variants = counts[term];
    const ranked = Object.keys(variants).sort((a, b) => variants[b] - variants[a]);
    const best = ranked[0];
    const bestCount = variants[best];
    const runnerUpCount = ranked[1] ? variants[ranked[1]] : 0;
    if (ranked.length > 1) {
      dbg('glossary: term', term, 'had conflicting translations', variants);
    }
    if (bestCount >= 2 && bestCount > runnerUpCount) {
      glossary[term] = best;
    } else if (ranked.length > 1) {
      dbg('glossary: term', term, 'has no clear consensus, dropping it entirely');
    }
  }
  if (!Object.keys(glossary).length) return null;
  await setCacheWithFallback(glossaryCacheKey, { v: CACHE_SCHEMA_VERSION, glossary: glossary, savedAt: Date.now() });
  return glossary;
}

async function handleLine(port, { text, targetLang }, isDead) {
  if (!text) return;
  const cacheId = targetLang + ' ' + text;
  if (lineCache.has(cacheId)) {
    safePost(port, { type: 'line-result', text: text, translation: lineCache.get(cacheId) }, isDead);
    return;
  }
  try {
    const res = await sendNative({ action: 'translate', lines: [text], targetLang: targetLang });
    if (!res || res.ok !== true || !Array.isArray(res.translations)) {
      throw Object.assign(new Error(res && res.error || 'native-error'), { code: res && res.error });
    }
    const translation = res.translations[0] != null ? String(res.translations[0]) : '';
    lineCache.set(cacheId, translation);
    if (lineCache.size > LINE_CACHE_MAX) {
      lineCache.delete(lineCache.keys().next().value);
    }
    safePost(port, { type: 'line-result', text: text, translation: translation }, isDead);
  } catch (e) {
    safePost(port, { type: 'line-result', text: text, code: e.code || classifyError(e) }, isDead);
  }
}

// S4: sweeps out anything left over from an older cache schema (episode and
// glossary entries share this prefix's LRU pool, see GLOSSARY_CACHE_PREFIX),
// then trims the remaining entries down to MAX_CACHED_EPISODES by age. Called
// after every successfully-completed episode, so a version bump gets cleaned
// up gradually rather than needing a dedicated migration pass.
async function pruneCache() {
  try {
    const all = await api.storage.local.get(null);
    const keys = Object.keys(all).filter((k) => k.startsWith(CACHE_PREFIX));
    const stale = keys.filter((k) => !all[k] || all[k].v !== CACHE_SCHEMA_VERSION);
    if (stale.length) await api.storage.local.remove(stale);

    const staleSet = new Set(stale);
    const fresh = keys
      .filter((k) => !staleSet.has(k))
      .map((k) => ({ key: k, savedAt: (all[k] && all[k].savedAt) || 0 }))
      .sort((a, b) => a.savedAt - b.savedAt);
    let survivingKeys = fresh.map((e) => e.key);
    if (fresh.length > MAX_CACHED_EPISODES) {
      const evict = fresh.slice(0, fresh.length - MAX_CACHED_EPISODES).map((e) => e.key);
      await api.storage.local.remove(evict);
      const evictSet = new Set(evict);
      survivingKeys = survivingKeys.filter((k) => !evictSet.has(k));
    }
    await pruneOrphanedTitleMeta(all, survivingKeys);
  } catch (e) { /* best effort */ }
}

// 2026-07-06: removes title-metadata entries whose corresponding
// translation-cache group no longer exists (evicted above by schema-version
// or LRU). Title metadata has no eviction mechanism of its own — it's
// deliberately kept outside CACHE_PREFIX's LRU pool (see TITLE_META_PREFIX's
// doc comment) — so without this cleanup it would accumulate forever.
async function pruneOrphanedTitleMeta(all, survivingCacheKeys) {
  const aliveRest = new Set();
  for (const key of survivingCacheKeys) {
    if (key.startsWith(GLOSSARY_CACHE_PREFIX)) aliveRest.add(key.slice(GLOSSARY_CACHE_PREFIX.length));
    else aliveRest.add(key.slice(CACHE_PREFIX.length));
  }
  const orphaned = Object.keys(all)
    .filter((k) => k.startsWith(TITLE_META_PREFIX) && !aliveRest.has(k.slice(TITLE_META_PREFIX.length)));
  if (orphaned.length) await api.storage.local.remove(orphaned);
}

// S4: evicts the `count` oldest cache entries regardless of
// MAX_CACHED_EPISODES — used when a write fails, since that's a total-bytes
// (QUOTA_BYTES) problem, not an entry-count one; a handful of long episodes
// can hit the byte quota well before MAX_CACHED_EPISODES entries accumulate.
async function evictOldestEntries(count) {
  try {
    const all = await api.storage.local.get(null);
    const entries = Object.keys(all)
      .filter((k) => k.startsWith(CACHE_PREFIX))
      .map((k) => ({ key: k, savedAt: (all[k] && all[k].savedAt) || 0 }))
      .sort((a, b) => a.savedAt - b.savedAt);
    if (!entries.length) return false;
    await api.storage.local.remove(entries.slice(0, Math.min(count, entries.length)).map((e) => e.key));
    return true;
  } catch (e) { return false; }
}

// S4: a `storage.local.set` write can fail outright when the extension is at
// its storage quota — previously this threw straight out of handleEpisode's
// batch loop and aborted an in-progress translation the user was already
// watching, even though the translation itself had succeeded and only the
// *cache write* failed. Evict the oldest entries to free room and retry
// once; if it still fails, give up on caching this batch quietly rather than
// losing the translation that's already in memory.
async function setCacheWithFallback(key, value) {
  try {
    await api.storage.local.set({ [key]: value });
    return true;
  } catch (e) {
    dbg('cache write failed, evicting oldest entries and retrying:', String(e && e.message || e));
    if (!(await evictOldestEntries(5))) return false;
    try {
      await api.storage.local.set({ [key]: value });
      return true;
    } catch (e2) {
      dbg('cache write retry still failed, continuing without caching this batch:', String(e2 && e2.message || e2));
      return false;
    }
  }
}

// D4: cache management moved into the App (2026-07-05) — the App has no
// direct access to storage.local, so this piggybacks both directions on the
// existing `ping` native message. See CacheSync's doc comment in
// TranslatorCore.swift for the full design and its staleness tradeoff.
function approxCacheBytes(key, value) {
  try { return new Blob([key + JSON.stringify(value)]).size; } catch (e) { return 0; }
}

// Groups the flat storage.local key space into one entry per
// movieId:targetLang:sourceLang, merging the episode entry with its
// (optional) glossary entry — same grouping the old cache.html UI used.
function buildCacheIndex(all) {
  const groups = {};
  function groupFor(rest) {
    if (!groups[rest]) {
      const [movieId, targetLang, sourceLang] = rest.split(':');
      groups[rest] = { movieId: movieId, targetLang: targetLang, sourceLang: sourceLang,
        lineCount: 0, bytes: 0, savedAt: 0, seriesTitle: null, episodeTitle: null, seasonNumber: null };
    }
    return groups[rest];
  }
  for (const key of Object.keys(all)) {
    // 2026-07-06: title metadata lives under its own prefix (see
    // TITLE_META_PREFIX's doc comment for why), merged into the same
    // movieId:targetLang:sourceLang group here at index-build time rather
    // than at write time — this is what avoids the write-ordering race with
    // handleEpisode's own cache writes.
    if (key.startsWith(TITLE_META_PREFIX)) {
      const g = groupFor(key.slice(TITLE_META_PREFIX.length));
      const meta = all[key] || {};
      g.seriesTitle = meta.seriesTitle || null;
      g.episodeTitle = meta.episodeTitle || null;
      g.seasonNumber = typeof meta.seasonNumber === 'number' ? meta.seasonNumber : null;
      continue;
    }
    if (!key.startsWith(CACHE_PREFIX)) continue;
    const value = all[key];
    const bytes = approxCacheBytes(key, value);
    const savedAt = (value && value.savedAt) || 0;
    if (key.startsWith(GLOSSARY_CACHE_PREFIX)) {
      const g = groupFor(key.slice(GLOSSARY_CACHE_PREFIX.length));
      g.bytes += bytes;
      g.savedAt = Math.max(g.savedAt, savedAt);
    } else {
      const g = groupFor(key.slice(CACHE_PREFIX.length));
      g.bytes += bytes;
      g.savedAt = Math.max(g.savedAt, savedAt);
      g.lineCount = Array.isArray(value && value.translations) ? value.translations.length : 0;
    }
  }
  // A title-only group (metadata arrived but the translation entry was
  // since evicted/never written) shouldn't surface as a phantom cache row.
  return Object.values(groups).filter((g) => g.bytes > 0 || g.lineCount > 0);
}

async function syncCacheIndex() {
  try {
    const all = await api.storage.local.get(null);
    return buildCacheIndex(all);
  } catch (e) {
    return [];
  }
}

// Applies a delete request the App queued (see handlePing's response —
// `cacheDeleteRequest`), reconstructing the actual storage.local keys from
// the movieId/targetLang/sourceLang tuple the App has no other knowledge of.
async function applyCacheDeleteRequest(req) {
  if (!req) return;
  try {
    if (req.clearAll) {
      const all = await api.storage.local.get(null);
      const keys = Object.keys(all).filter((k) => k.startsWith(CACHE_PREFIX) || k.startsWith(TITLE_META_PREFIX));
      if (keys.length) await api.storage.local.remove(keys);
      return;
    }
    if (Array.isArray(req.groups) && req.groups.length) {
      const keys = [];
      for (const g of req.groups) {
        const rest = g.movieId + ':' + g.targetLang + ':' + g.sourceLang;
        keys.push(CACHE_PREFIX + rest, GLOSSARY_CACHE_PREFIX + rest, TITLE_META_PREFIX + rest);
      }
      await api.storage.local.remove(keys);
    }
  } catch (e) { dbg('applyCacheDeleteRequest failed:', String(e && e.message || e)); }
}

async function pingNative() {
  const cacheIndex = await syncCacheIndex();
  const res = await sendNative({ action: 'ping', cacheIndex: cacheIndex });
  if (res && res.cacheDeleteRequest) {
    applyCacheDeleteRequest(res.cacheDeleteRequest).catch(() => {});
  }
  return res;
}

// V4: relays content.js's already-gated (vocab-design.md §4) transcript to
// the two native calls content.js has no direct channel for — first landing
// the text (`save-transcript`), then waking the App on the vocab tab
// (`open-app` with destination:"vocab"). If the save fails, don't bother
// trying to open the App at all; there'd be nothing for it to pick up.
async function organizeVocab(payload) {
  const saveRes = await sendNative({
    action: 'save-transcript',
    movieId: payload.movieId,
    seriesTitle: payload.seriesTitle,
    episodeTitle: payload.episodeTitle,
    seasonNumber: payload.seasonNumber,
    sourceLang: payload.sourceLang,
    targetLang: payload.targetLang,
    lines: payload.lines
  });
  if (!saveRes || saveRes.ok !== true) {
    return saveRes || { ok: false, error: 'empty-response' };
  }
  return sendNative({ action: 'open-app', destination: 'vocab', movieId: payload.movieId });
}

// Popup queries (native app / model status).
api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === 'ping-native') {
    pingNative()
      .then((res) => sendResponse(res || { ok: false, error: 'empty-response' }))
      .catch((e) => sendResponse({ ok: false, error: classifyError(e) }));
    return true; // async response
  }
  if (msg && msg.type === 'open-app') {
    // D1: popup's "進階樣式設定…" button — wakes/launches the host app via
    // its multisub:// URL scheme (see SafariWebExtensionHandler.handleOpenApp).
    sendNative({ action: 'open-app' })
      .then((res) => sendResponse(res || { ok: false, error: 'empty-response' }))
      .catch((e) => sendResponse({ ok: false, error: classifyError(e) }));
    return true; // async response
  }
  if (msg && msg.type === 'organize-vocab') {
    organizeVocab(msg.payload)
      .then((res) => sendResponse(res || { ok: false, error: 'empty-response' }))
      .catch((e) => sendResponse({ ok: false, error: classifyError(e) }));
    return true; // async response
  }
  return false;
});

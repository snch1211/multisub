// Background script: job runner between the content scripts and the native
// Safari extension handler, which runs the AI engine (the local MLX model or
// the user's own cloud API key).
//
// - Splits an episode into chunks (translate: fixed batches; annotate:
//   scene-sized chunks) and works through them starting where the viewer is,
//   with more parallel requests for cloud engines than for the local model.
// - Caches finished (and partial) results in storage.local, keyed by
//   movieId + target language + source track language, so re-watching costs
//   nothing and interrupted jobs resume where they stopped.
// - Shares a running job between tabs showing the same episode, mode and
//   languages, and skips a chunk that keeps failing instead of giving up on
//   the episode (the job then ends with done{partial: true}).
// - Forwards the popup's engine/preference requests to the native handler.
//
// Loaded after shared.js (globalThis.MS).
'use strict';

// Load diagnostics. If anything below throws while this page loads (an API
// Safari lacks, shared.js missing or mis-decoded), the real message listener never gets
// registered and the popup would only learn that nobody answered. This
// responder is registered first and, until the whole file has run, answers
// with the error that stopped it, so the popup can show the actual cause.
const bootErrors = [];
(function installBootDiagnostics() {
  const api0 = typeof browser !== 'undefined' ? browser : chrome;
  const where = (file, line) => (file ? String(file).split('/').pop() + ':' + line : '');
  if (typeof globalThis.addEventListener === 'function') {
    globalThis.addEventListener('error', (e) => {
      bootErrors.push([e.message, where(e.filename, e.lineno)].filter(Boolean).join(' @ '));
    });
    globalThis.addEventListener('unhandledrejection', (e) => {
      bootErrors.push('unhandled: ' + String((e.reason && e.reason.message) || e.reason));
    });
  }
  // shared.js is loaded by background.html just before this file. If it
  // isn't there, check that background.html still declares UTF-8.
  if (typeof MS === 'undefined') bootErrors.push('shared.js did not load');
  api0.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (globalThis.__multisubBackgroundReady) return false;
    sendResponse({
      ok: false,
      error: 'native-unavailable',
      detail: '背景程式載入失敗：' + (bootErrors.join('；') || '原因不明')
    });
    return false;
  });
})();

const api = typeof browser !== 'undefined' ? browser : chrome;

// Set to true, reload the extension, and check the *background page's* Web
// Inspector console (Safari → Develop → Web Extension Background Content →
// MultiSub, not the Netflix tab's console).
const DEBUG = false;
function dbg() {
  if (!DEBUG) return;
  try { console.log.apply(console, ['[MultiSub][background]'].concat([].slice.call(arguments))); } catch (e) { /* ignore */ }
}

// Safari routes native messages to the containing app; the id is ignored.
const NATIVE_APP_ID = 'application.id';
const MAX_CACHED_EPISODES = 40;
// Bumped whenever a cached entry's stored shape changes in a way that isn't
// already caught by other checks (e.g. `translations.length === lines.length`):
// entries written under an older version are treated as a miss and swept by
// pruneCache, instead of risking a stale-shaped read.
const CACHE_SCHEMA_VERSION = 1;
// Episode-wide name/term glossary for translate jobs, built from
// source/official-subtitle pairs and cached under MS.glossaryKey.
const GLOSSARY_SEGMENT_SIZE = 40; // pairs per extract-glossary call
const GLOSSARY_MIN_PAIRS = 8; // below this, a glossary pass isn't worth the extra calls
// Series/episode/season metadata for a cache group, keyed by the same
// movieId:targetLang:sourceLang group but deliberately NOT under 'ms:': a
// title object has no `.v` field, so pruneCache's stale-schema sweep would
// delete it after every episode, and it shouldn't eat into
// MAX_CACHED_EPISODES either. Written fire-and-forget by content.js,
// independently of the job's own cache writes; keeping it a separate key
// avoids a write-ordering race between the two.
const TITLE_META_PREFIX = 'mstitle:';

// Cloud providers answer fast and in parallel; the local model runs one
// request at a time and slows down with long prompts.
const ENGINE_PROFILES = {
  cloud: { batch: 24, workers: 3 },
  local: { batch: 12, workers: 1 }
};
const ENGINE_MAX_AGE_MS = 30000;
// Safari unloads a non-persistent background page 30 s after the last event
// and doesn't count a pending sendNativeMessage, but port traffic does count.
// A local-model chunk can take longer than that, so post something on the
// job's port at least this often.
const HEARTBEAT_MS = 15000;
const RETRY_DELAYS_MS = [2000, 6000];
// Retried with RETRY_DELAYS_MS before a chunk is given up on.
const TRANSIENT_CODES = new Set(['rate-limited', 'network', 'provider-error']);
// Codes no other chunk can get past (the engine itself isn't usable), so the
// whole job stops. Anything else only costs the chunk that hit it: one batch
// that keeps failing (say, a local server whose context window is a little
// too small for it) must not keep every later line untranslated.
const FATAL_CODES = new Set(['auth-failed', 'engine-not-ready', 'model-not-ready', 'consent-required', 'native-unavailable']);
// ...unless chunks keep failing one after another, which means the service
// is down rather than one batch being odd.
const MAX_CONSECUTIVE_CHUNK_FAILURES = 3;
const KNOWN_CODES = new Set(Object.keys(MS.ERROR_TEXT));

// Bumped per job key whenever a job for that key is replaced by one with
// different input, so the stale loop stops itself.
const generations = new Map();
const runningJobs = new Set();
// Job key -> the job currently running for it. A second tab on the same
// episode, mode and languages joins that job instead of starting (and paying
// for) a second one; see startJob.
const jobsByKey = new Map();

// Last engine object from a native `ping` / `set-engine`, see ARCHITECTURE §5.2.
let engineInfo = { engine: null, at: 0 };

// Small LRU for the DOM-fallback line path.
const lineCache = new Map();
const LINE_CACHE_MAX = 500;
// The local model runs one request at a time, and on a cold start every
// concurrent request can start its own multi-GB model load. So on the local
// engine at most one fallback line is sent to native at a time; while it
// runs, each tab keeps only its newest waiting line (the older ones are no
// longer on screen) and is told the older ones were dropped.
const lineGate = { busy: false, waiting: new Map() }; // conn -> 'line' msg

// ---------------------------------------------------------------------------
// Native messaging
// ---------------------------------------------------------------------------
function nativeError(code, detail) {
  return Object.assign(new Error(detail || code), { code: code, detail: detail || '' });
}

// Older native builds reported free-form codes such as
// "translate-failed: <message>"; fold those into the codes the UI knows.
function normalizeCode(code) {
  const c = String(code || '');
  if (KNOWN_CODES.has(c)) return c;
  if (!c || /^(translate|annotate|extract-glossary)-failed/.test(c) ||
      c === 'bad-request' || c === 'empty-response' || c === 'native-error') {
    return 'provider-error';
  }
  return c;
}

// Any rejection from sendNativeMessage itself means the native side couldn't
// be reached; error replies ({ok: false}) are left to the caller.
async function sendNative(message) {
  try {
    return await api.runtime.sendNativeMessage(NATIVE_APP_ID, message);
  } catch (e) {
    throw nativeError('native-unavailable', String(e && e.message || e));
  }
}

function expectOk(res) {
  if (!res || res.ok !== true) {
    const raw = res && res.error || 'empty-response';
    throw nativeError(normalizeCode(raw), (res && res.detail) || String(raw));
  }
  return res;
}

function rememberEngine(engine) {
  if (engine && typeof engine === 'object') engineInfo = { engine: engine, at: Date.now() };
}

async function currentEngine() {
  if (Date.now() - engineInfo.at > ENGINE_MAX_AGE_MS) {
    try { await pingNative(); } catch (e) { dbg('engine refresh failed:', e.code); }
  }
  return engineInfo.engine;
}

function profileFor(engine) {
  return engine && engine.active === 'cloud' ? ENGINE_PROFILES.cloud : ENGINE_PROFILES.local;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Ports from content scripts
// ---------------------------------------------------------------------------
api.runtime.onConnect.addListener((port) => {
  if (port.name !== 'multisub') return;
  const conn = { port: port, dead: false, job: null, lastPostAt: Date.now() };
  port.onDisconnect.addListener(() => {
    conn.dead = true;
    lineGate.waiting.delete(conn);
    // The tab closed, navigated away, or moved on to a different job on a
    // fresh port: stop spending model/API calls on this one (unless another
    // tab still watches the same job). If content.js still wants it, it
    // reconnects and re-sends the job, and the finished chunks replay from
    // the cache.
    if (conn.job) leaveJob(conn.job, conn);
  });
  port.onMessage.addListener((msg) => {
    if (!msg || typeof msg.type !== 'string') return;
    if (msg.type === 'job') startJob(conn, msg);
    else if (msg.type === 'prioritize') prioritize(conn, msg);
    else if (msg.type === 'line') handleLine(conn, msg);
    else if (msg.type === 'episode-title') handleEpisodeTitle(msg);
    // 'keepalive' needs no handling: receiving it is what keeps Safari from
    // unloading this page while a job is running.
  });
});

function post(conn, msg) {
  if (conn.dead) return false;
  try {
    conn.port.postMessage(msg);
    conn.lastPostAt = Date.now();
    return true;
  } catch (e) {
    return false;
  }
}

let heartbeatTimer = null;
function ensureHeartbeat() {
  if (heartbeatTimer) return;
  heartbeatTimer = setInterval(() => {
    if (!runningJobs.size) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
      return;
    }
    const now = Date.now();
    for (const job of runningJobs) {
      for (const conn of job.subs) {
        if (now - conn.lastPostAt >= HEARTBEAT_MS - 2500) post(conn, { type: 'heartbeat' });
      }
    }
  }, 5000);
}

// Every tab watching a job gets its messages.
function postJob(job, msg) {
  for (const conn of job.subs) post(conn, msg);
}

// Turning MultiSub off releases the local model's multi-GB footprint right
// away instead of leaving it resident until Safari reclaims the extension
// process, and stops every job before its next chunk (a chunk already in
// flight still completes; its result is dropped).
api.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.settings) return;
  const wasEnabled = (changes.settings.oldValue || {}).enabled !== false;
  const isEnabled = (changes.settings.newValue || {}).enabled !== false;
  if (!(wasEnabled && !isEnabled)) return;
  dbg('settings.enabled -> false: stopping jobs, unloading model');
  for (const job of runningJobs) job.cancel();
  for (const key of generations.keys()) generations.set(key, (generations.get(key) || 0) + 1);
  sendNative({ action: 'unload' }).catch((e) => dbg('unload failed:', e.code));
});

// ---------------------------------------------------------------------------
// Jobs (ARCHITECTURE §5.1)
// ---------------------------------------------------------------------------
function sanitizeAnnotations(list) {
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const a of list) {
    if (!a || typeof a.term !== 'string' || typeof a.gloss !== 'string') continue;
    const term = a.term.trim();
    const gloss = a.gloss.trim();
    if (term && gloss) out.push({ term: term, gloss: gloss });
  }
  return out;
}

function isComplete(items, start, end) {
  for (let i = start; i < end; i++) if (items[i] == null) return false;
  return true;
}

// Same episode, mode, languages and level, so a second tab can share the
// running job. The lines are compared as well: two tracks in one language
// (full subtitles and closed captions) share a cache key but not their text.
function sameJobInput(job, lines, level) {
  if (job.level !== level || job.lines.length !== lines.length) return false;
  for (let i = 0; i < lines.length; i++) if (job.lines[i] !== lines[i]) return false;
  return true;
}

// A tab stops watching a job (it closed, or moved on to another mode,
// language or episode). The job keeps going while any other tab watches it.
function leaveJob(job, conn) {
  job.subs.delete(conn);
  if (conn.job === job) conn.job = null;
  if (!job.subs.size) job.cancel();
}

function joinJob(job, conn, startIndex) {
  job.subs.add(conn);
  conn.job = job;
  if (job.items.some((x) => x != null)) {
    post(conn, { type: 'progress', kind: job.kind, start: 0, items: job.items.slice() });
  }
  // The tab that just started is the one whose viewer is waiting for lines.
  if (job.queue.length) job.queue = MS.orderChunks(job.queue, startIndex, job.lines.length);
  dbg('job', job.key, 'joined, tabs:', job.subs.size);
}

async function startJob(conn, msg) {
  const kind = msg.kind === 'translate' || msg.kind === 'annotate' ? msg.kind : null;
  if (!kind || !msg.movieId || !Array.isArray(msg.lines) || !msg.lines.length) return;
  const n = msg.lines.length;
  const movieId = String(msg.movieId);
  const targetLang = String(msg.targetLang || '');
  const sourceLang = String(msg.sourceLang || '');
  const lines = msg.lines.map((l) => (l == null ? '' : String(l)));
  const level = String(msg.level || MS.DEFAULT_SETTINGS.annotateLevel);
  const startIndex = Math.max(0, Math.min(n - 1, Number(msg.startIndex) || 0));
  // Source track language is part of the key: the same episode watched with a
  // different source subtitle track is a different transcript.
  const key = kind + '|' + MS.cacheGroup(movieId, targetLang, sourceLang);
  // A tab shows one mode in one language at a time, so the job it started
  // before this one (another mode, another language) is no longer wanted.
  if (conn.job) leaveJob(conn.job, conn);

  const running = jobsByKey.get(key);
  if (running && !running.stopped() && sameJobInput(running, lines, level)) {
    joinJob(running, conn, startIndex);
    return;
  }
  if (running && !running.ended && running.subs.size && !running.failure) {
    // Different input for the same cache entry: this job replaces that one
    // (two jobs would overwrite each other's cache writes). The tabs still
    // on it get a terminal message instead of waiting for a 'done' that
    // never comes; they re-send later and replay what this job cached.
    // (A job that already failed keeps its tabs: they get its error.)
    postJob(running, { type: 'superseded', kind: kind });
    for (const c of Array.from(running.subs)) {
      running.subs.delete(c);
      if (c.job === running) c.job = null;
    }
  }
  const generation = (generations.get(key) || 0) + 1;
  generations.set(key, generation);

  const job = {
    kind: kind,
    key: key,
    subs: new Set([conn]), // conns of the tabs watching this job
    movieId: movieId,
    targetLang: targetLang,
    sourceLang: sourceLang,
    level: level,
    lines: lines,
    referenceLines: Array.isArray(msg.referenceLines) && msg.referenceLines.length === n
      ? msg.referenceLines.map((r) => (r == null ? null : String(r))) : null,
    starts: Array.isArray(msg.starts) && msg.starts.length === n ? msg.starts.map(Number) : null,
    startIndex: startIndex,
    cacheKey: kind === 'translate'
      ? MS.translateKey(movieId, targetLang, sourceLang)
      : MS.annotateKey(movieId, targetLang, sourceLang),
    items: new Array(n).fill(null),
    queue: [],
    glossary: { ready: false, value: null },
    glossaryDeferred: false,
    failedChunks: 0,
    consecutiveFailures: 0,
    lastChunkError: null,
    cancelled: false,
    failure: null,
    ended: false,
    save: { running: null, again: false }
  };
  job.cancel = () => { job.cancelled = true; };
  job.superseded = () => job.cancelled || generations.get(key) !== generation;
  job.stopped = () => job.superseded() || !!job.failure;

  conn.job = job;
  jobsByKey.set(key, job);
  runningJobs.add(job);
  ensureHeartbeat();
  try {
    await runJob(job);
  } catch (e) {
    if (!job.failure) job.failure = e;
  } finally {
    // Also what stops a glossary still being built for this job.
    job.ended = true;
    runningJobs.delete(job);
    if (jobsByKey.get(key) === job) jobsByKey.delete(key);
  }
  // Whoever still watches gets the error. A tab that moved on or was handed
  // 'superseded' has already left job.subs; a cancelled job reports nothing.
  if (job.failure && !job.cancelled && job.subs.size) {
    const code = job.failure.code ? normalizeCode(job.failure.code) : 'provider-error';
    dbg('job failed:', key, code, job.failure.detail);
    postJob(job, { type: 'error', kind: kind, code: code, detail: String(job.failure.detail || job.failure.message || '') });
  }
  for (const c of job.subs) if (c.job === job) c.job = null;
}

async function runJob(job) {
  const n = job.lines.length;
  const profile = profileFor(await currentEngine());
  if (job.stopped()) return;

  await loadCachedItems(job);
  if (job.stopped()) return;
  // Replay whatever we already have.
  if (job.items.some((x) => x != null)) {
    postJob(job, { type: 'progress', kind: job.kind, start: 0, items: job.items.slice() });
  }
  if (isComplete(job.items, 0, n)) {
    postJob(job, { type: 'done', kind: job.kind, fromCache: true });
    return;
  }

  let chunks;
  if (job.kind === 'translate') chunks = MS.fixedChunks(n, profile.batch);
  else if (job.starts) chunks = MS.chunkCues(job.starts, 16, 8, 5);
  else chunks = MS.fixedChunks(n, 16);
  // Start with the chunk the viewer is watching, then carry on forward and
  // wrap around to the beginning.
  job.queue = MS.orderChunks(chunks, job.startIndex, n)
    .filter((c) => !isComplete(job.items, c[0], c[1]));
  dbg('job', job.key, 'chunks:', job.queue.length, 'workers:', profile.workers);

  if (job.kind === 'translate') {
    // On the local model the glossary waits until the first batch is back:
    // sent together on a cold start, both requests would load the model at
    // once, and the viewer is waiting for the batch, not the glossary.
    if (profile === ENGINE_PROFILES.local) job.glossaryDeferred = true;
    else startGlossary(job);
  }

  const workers = [];
  for (let i = 0; i < Math.min(profile.workers, job.queue.length); i++) workers.push(runWorker(job));
  await Promise.all(workers);
  await flushSave(job);
  if (job.stopped()) return;
  await pruneCache();
  if (job.failedChunks) {
    const e = job.lastChunkError;
    if (!job.items.some((x) => x != null)) {
      // Not a single line to show: that's a failed job, not a partial one.
      job.failure = e;
      return;
    }
    // The failed chunks stay null, in memory and in the cache, so the next
    // job for this episode (content.js retries later) only redoes those.
    const missing = job.items.reduce((count, x) => count + (x == null ? 1 : 0), 0);
    postJob(job, {
      type: 'done', kind: job.kind, partial: true, missing: missing,
      code: e && e.code ? normalizeCode(e.code) : 'provider-error'
    });
    return;
  }
  postJob(job, { type: 'done', kind: job.kind });
}

async function loadCachedItems(job) {
  const n = job.lines.length;
  try {
    const stored = (await api.storage.local.get(job.cacheKey))[job.cacheKey];
    if (!stored || stored.v !== CACHE_SCHEMA_VERSION) return;
    if (job.kind === 'translate') {
      if (Array.isArray(stored.translations) && stored.translations.length === n) {
        job.items = stored.translations.map((t) => (t == null ? null : String(t)));
      }
    } else if (stored.level === job.level && Array.isArray(stored.annotations) && stored.annotations.length === n) {
      job.items = stored.annotations.map((a) => (a == null ? null : sanitizeAnnotations(a)));
    }
  } catch (e) { /* treat as no cache */ }
}

function cacheValue(job) {
  if (job.kind === 'translate') {
    return {
      v: CACHE_SCHEMA_VERSION, translations: job.items.slice(), savedAt: Date.now(),
      targetLang: job.targetLang, sourceLang: job.sourceLang
    };
  }
  return { v: CACHE_SCHEMA_VERSION, level: job.level, annotations: job.items.slice(), savedAt: Date.now() };
}

// Workers finish chunks out of order, so writes are coalesced: one write at a
// time, always of the latest in-memory state, never of an older snapshot.
function scheduleSave(job) {
  if (job.save.running) {
    job.save.again = true;
    return job.save.running;
  }
  job.save.running = (async () => {
    do {
      job.save.again = false;
      if (job.superseded()) break; // a newer job for this key owns the entry now
      await setCacheWithFallback(job.cacheKey, cacheValue(job));
    } while (job.save.again);
    job.save.running = null;
  })();
  return job.save.running;
}

async function flushSave(job) {
  while (job.save.running) await job.save.running;
}

async function runWorker(job) {
  while (!job.stopped()) {
    const chunk = job.queue.shift();
    if (!chunk) return;
    if (isComplete(job.items, chunk[0], chunk[1])) continue;
    try {
      await runChunkWithRetry(job, chunk);
    } catch (e) {
      if (job.stopped()) return;
      const code = e && e.code ? normalizeCode(e.code) : 'provider-error';
      if (FATAL_CODES.has(code) || ++job.consecutiveFailures >= MAX_CONSECUTIVE_CHUNK_FAILURES) {
        if (!job.failure) job.failure = e;
        return;
      }
      // Give up on this chunk only: its items stay null (never cached as
      // '' or []), so a later job retries exactly these lines, and the
      // worker moves on to the next chunk.
      job.failedChunks++;
      job.lastChunkError = e;
      dbg('chunk', chunk, 'skipped after', code);
    }
  }
}

async function runChunkWithRetry(job, chunk) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await runChunk(job, chunk);
    } catch (e) {
      if (job.stopped() || !TRANSIENT_CODES.has(e.code) || attempt >= RETRY_DELAYS_MS.length) throw e;
      dbg('chunk', chunk, 'failed with', e.code, '- retrying');
      await sleep(RETRY_DELAYS_MS[attempt]);
      if (job.stopped()) return;
    }
  }
}

async function runChunk(job, chunk) {
  const start = chunk[0];
  const end = chunk[1];
  const lines = job.lines.slice(start, end);
  let results;
  if (job.kind === 'translate') {
    const glossary = job.glossary.ready ? job.glossary.value : null;
    // Pass this batch's aligned official-subtitle lines unless the glossary
    // is ready: sending both would just burn tokens for no benefit.
    const reference = !glossary && job.referenceLines ? job.referenceLines.slice(start, end) : null;
    const res = expectOk(await sendNative({
      action: 'translate', lines: lines, targetLang: job.targetLang,
      reference: reference, glossary: glossary
    }));
    if (!Array.isArray(res.translations)) throw nativeError('provider-error', 'reply has no translations');
    // A non-empty line that comes back empty was refused by the provider or
    // got no answer (Translator.translate returns "" for just that line).
    // It stays null, in memory and in the cache, so a later job asks again
    // instead of the blank being cached for good. It doesn't make the chunk
    // a failed one: asking again right away would most likely be refused
    // again, and a refused batch is redone one line per call.
    results = lines.map((line, j) => {
      const t = res.translations[j];
      if (t != null && String(t).trim()) return String(t);
      return line.trim() ? null : '';
    });
  } else {
    const res = expectOk(await sendNative({
      action: 'annotate',
      lines: lines,
      // Two read-only lines before the chunk, so a chunk boundary never
      // strands a pronoun or a sentence split across cues.
      context: job.lines.slice(Math.max(0, start - 2), start),
      reference: job.referenceLines ? job.referenceLines.slice(start, end) : lines.map(() => null),
      sourceLang: job.sourceLang,
      targetLang: job.targetLang,
      level: job.level
    }));
    if (!Array.isArray(res.annotations)) throw nativeError('provider-error', 'reply has no annotations');
    results = lines.map((_, j) => sanitizeAnnotations(res.annotations[j]));
  }
  if (job.superseded()) return;
  job.consecutiveFailures = 0;
  for (let j = 0; j < results.length; j++) job.items[start + j] = results[j];
  scheduleSave(job);
  postJob(job, { type: 'progress', kind: job.kind, start: start, items: results });
  if (job.glossaryDeferred) {
    job.glossaryDeferred = false;
    startGlossary(job);
  }
}

// The viewer seeked: work on the chunks at/after `index` first.
function prioritize(conn, msg) {
  const movieId = String(msg.movieId || '');
  let job = conn.job;
  if (!job || job.kind !== msg.kind || job.movieId !== movieId) {
    job = null;
    for (const j of runningJobs) {
      if (j.kind === msg.kind && j.movieId === movieId) { job = j; break; }
    }
  }
  if (!job || job.stopped() || !job.queue.length) return;
  const index = Math.max(0, Number(msg.index) || 0);
  job.queue = MS.orderChunks(job.queue, index, job.lines.length);
  dbg('prioritize', job.key, 'index', index, 'next chunk', job.queue[0]);
}

// Kicked off alongside the batches, not awaited: early batches use the
// per-line official reference; once the glossary resolves, later batches
// switch to it. It is cheaper per request and also helps lines with no
// aligned official cue. It lives only as long as its job: once the job is
// done, failed or replaced (job.ended also covers a closed tab, since a job
// whose last tab disconnects is cancelled), a glossary can't help any batch,
// so the remaining extract-glossary calls aren't made.
function startGlossary(job) {
  const stale = () => job.superseded() || !!job.failure || job.ended;
  resolveGlossary(job.movieId, job.targetLang, job.sourceLang, job.lines, job.referenceLines, stale)
    .then((g) => {
      job.glossary.ready = true;
      job.glossary.value = g;
      dbg('glossary ready for', job.key, '- terms:', g ? Object.keys(g).length : 0);
    })
    .catch((e) => {
      job.glossary.ready = true;
      job.glossary.value = null;
      dbg('glossary failed for', job.key, String(e && e.message || e));
    });
}

// Builds (or reuses a cached) episode-wide glossary from the source/official
// pairs aligned by content.js. Segmented into GLOSSARY_SEGMENT_SIZE pairs per
// native call so each prompt stays bounded; a failed or empty segment just
// contributes nothing, since one bad segment shouldn't sink the glossary.
async function resolveGlossary(movieId, targetLang, sourceLang, lines, referenceLines, stale) {
  if (!Array.isArray(referenceLines)) return null;
  const glossaryCacheKey = MS.glossaryKey(movieId, targetLang, sourceLang);
  try {
    const stored = (await api.storage.local.get(glossaryCacheKey))[glossaryCacheKey];
    if (stored && stored.v === CACHE_SCHEMA_VERSION && stored.glossary && Object.keys(stored.glossary).length) {
      return stored.glossary;
    }
  } catch (e) { /* treat as no cache */ }

  const pairs = [];
  for (let i = 0; i < lines.length; i++) {
    if (referenceLines[i]) pairs.push({ source: lines[i], reference: referenceLines[i] });
  }
  if (pairs.length < GLOSSARY_MIN_PAIRS) return null;

  // Tally translations per term across all segments instead of letting the
  // last segment overwrite earlier ones: one misaligned pair (alignment by
  // time isn't perfect) shouldn't clobber a term most segments agreed on.
  const counts = {}; // term -> { translation -> occurrences }
  for (let i = 0; i < pairs.length; i += GLOSSARY_SEGMENT_SIZE) {
    if (stale()) return null;
    const segment = pairs.slice(i, i + GLOSSARY_SEGMENT_SIZE);
    try {
      const res = await sendNative({ action: 'extract-glossary', pairs: segment, targetLang: targetLang });
      if (res && res.ok === true && res.glossary && typeof res.glossary === 'object') {
        for (const term of Object.keys(res.glossary)) {
          const translation = res.glossary[term];
          if (!translation) continue;
          if (!counts[term]) counts[term] = {};
          counts[term][translation] = (counts[term][translation] || 0) + 1;
        }
      }
    } catch (e) { dbg('glossary: segment', i, 'failed', e.code); }
  }

  // Extraction over a 40-pair segment occasionally shuffles term/translation
  // attributions (a name paired with an unrelated place or another
  // character), and a single stray hit could still "win" a naive majority
  // vote if nothing else was extracted for that term. So a term is only
  // trusted with a clear winner: 2+ corroborating extractions AND strictly
  // more than the runner-up. Anything murkier is dropped; the model's own
  // judgement for that name beats injecting a wrong term episode-wide.
  const glossary = {};
  for (const term of Object.keys(counts)) {
    const variants = counts[term];
    const ranked = Object.keys(variants).sort((a, b) => variants[b] - variants[a]);
    const bestCount = variants[ranked[0]];
    const runnerUpCount = ranked[1] ? variants[ranked[1]] : 0;
    if (bestCount >= 2 && bestCount > runnerUpCount) glossary[term] = ranked[0];
  }
  if (!Object.keys(glossary).length) return null;
  await setCacheWithFallback(glossaryCacheKey, { v: CACHE_SCHEMA_VERSION, glossary: glossary, savedAt: Date.now() });
  return glossary;
}

// DOM fallback: one line at a time, for either kind.
function handleLine(conn, msg) {
  const kind = msg.kind === 'annotate' ? 'annotate' : 'translate';
  const text = msg.text == null ? '' : String(msg.text);
  if (!text) return;
  const targetLang = String(msg.targetLang || '');
  const level = String(msg.level || MS.DEFAULT_SETTINGS.annotateLevel);
  const cacheId = [kind, targetLang, kind === 'annotate' ? level : '', text].join('\u0000');
  if (lineCache.has(cacheId)) {
    const hit = lineCache.get(cacheId);
    lineCache.delete(cacheId); // re-insert: most recently used goes last
    lineCache.set(cacheId, hit);
    post(conn, { type: 'line-result', kind: kind, text: text, result: hit });
    return;
  }
  // The cached engine info is enough here (no ping per line); unknown counts
  // as local, the side where one request at a time matters.
  if (profileFor(engineInfo.engine) !== ENGINE_PROFILES.local) {
    runLine(conn, msg, kind, text, targetLang, level, cacheId);
    return;
  }
  if (lineGate.busy) {
    const older = lineGate.waiting.get(conn);
    if (older) {
      post(conn, { type: 'line-result', kind: older.kind === 'annotate' ? 'annotate' : 'translate', text: String(older.text), dropped: true });
    }
    lineGate.waiting.set(conn, msg);
    return;
  }
  lineGate.busy = true;
  runLine(conn, msg, kind, text, targetLang, level, cacheId).finally(() => {
    lineGate.busy = false;
    drainLineGate();
  });
}

function drainLineGate() {
  // handleLine takes the gate synchronously when it sends to native, which
  // ends this loop; cache hits and dead tabs don't, so keep going past them.
  while (!lineGate.busy && lineGate.waiting.size) {
    const [conn, msg] = lineGate.waiting.entries().next().value;
    lineGate.waiting.delete(conn);
    if (!conn.dead) handleLine(conn, msg);
  }
}

async function runLine(conn, msg, kind, text, targetLang, level, cacheId) {
  try {
    let result;
    if (kind === 'translate') {
      const res = expectOk(await sendNative({ action: 'translate', lines: [text], targetLang: targetLang }));
      result = Array.isArray(res.translations) && res.translations[0] != null ? String(res.translations[0]) : '';
    } else {
      const res = expectOk(await sendNative({
        action: 'annotate', lines: [text], context: [], reference: [null],
        // `sourceLang` is an optional extra on the 'line' message: the DOM
        // fallback only knows the language Netflix's player reported, if any.
        sourceLang: String(msg.sourceLang || ''), targetLang: targetLang, level: level
      }));
      result = sanitizeAnnotations(Array.isArray(res.annotations) ? res.annotations[0] : null);
    }
    // An empty translation is a refusal or a missing answer (see runChunk),
    // not something to hand every tab for the rest of the session.
    if (kind !== 'translate' || result.trim()) {
      lineCache.set(cacheId, result);
      while (lineCache.size > LINE_CACHE_MAX) lineCache.delete(lineCache.keys().next().value);
    }
    post(conn, { type: 'line-result', kind: kind, text: text, result: result });
  } catch (e) {
    post(conn, { type: 'line-result', kind: kind, text: text, code: e.code ? normalizeCode(e.code) : 'native-unavailable' });
  }
}

// Records series/episode/season metadata for this episode's cache group, for
// the app's cache-management tab (real titles, grouped by series, instead of
// a bare movieId). Best effort: never required for subtitles themselves.
async function handleEpisodeTitle({ movieId, targetLang, sourceLang, seriesTitle, episodeTitle, seasonNumber }) {
  if (!movieId || !seriesTitle) return;
  const key = TITLE_META_PREFIX + MS.cacheGroup(movieId, targetLang, sourceLang);
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

// ---------------------------------------------------------------------------
// Cache maintenance
// ---------------------------------------------------------------------------

// Group part (movieId:targetLang:sourceLang) of any 'ms:' cache key.
function cacheGroupOfKey(key) {
  if (key.startsWith(MS.GLOSSARY_PREFIX)) return key.slice(MS.GLOSSARY_PREFIX.length);
  if (key.startsWith(MS.ANNOTATE_PREFIX)) return key.slice(MS.ANNOTATE_PREFIX.length);
  return key.slice(MS.CACHE_PREFIX.length);
}

// Sweeps out anything left over from an older cache schema (translation,
// glossary and annotation entries share the 'ms:' LRU pool), then trims the
// rest down to MAX_CACHED_EPISODES by age. Called after every completed job,
// so a version bump gets cleaned up gradually without a migration pass.
async function pruneCache() {
  try {
    const all = await api.storage.local.get(null);
    const keys = Object.keys(all).filter((k) => k.startsWith(MS.CACHE_PREFIX));
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

// Removes title metadata whose cache group no longer exists. Title metadata
// has no eviction of its own (it lives outside the 'ms:' pool, see
// TITLE_META_PREFIX), so without this it would accumulate forever.
async function pruneOrphanedTitleMeta(all, survivingCacheKeys) {
  const alive = new Set(survivingCacheKeys.map(cacheGroupOfKey));
  const orphaned = Object.keys(all)
    .filter((k) => k.startsWith(TITLE_META_PREFIX) && !alive.has(k.slice(TITLE_META_PREFIX.length)));
  if (orphaned.length) await api.storage.local.remove(orphaned);
}

// Evicts the `count` oldest cache entries regardless of MAX_CACHED_EPISODES:
// used when a write fails, which is a total-bytes quota problem, not an
// entry-count one (a handful of long episodes can hit the quota first).
async function evictOldestEntries(count) {
  try {
    const all = await api.storage.local.get(null);
    const entries = Object.keys(all)
      .filter((k) => k.startsWith(MS.CACHE_PREFIX))
      .map((k) => ({ key: k, savedAt: (all[k] && all[k].savedAt) || 0 }))
      .sort((a, b) => a.savedAt - b.savedAt);
    if (!entries.length) return false;
    await api.storage.local.remove(entries.slice(0, Math.min(count, entries.length)).map((e) => e.key));
    return true;
  } catch (e) { return false; }
}

// A storage.local write can fail outright at the storage quota. The results
// themselves are fine (they're already in memory and on screen), so free some
// room and retry once; if that fails too, skip caching this write quietly
// instead of aborting the job.
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
      dbg('cache write retry still failed:', String(e2 && e2.message || e2));
      return false;
    }
  }
}

// Cache management lives in the app, which can't read storage.local, so both
// directions piggyback on the native `ping`: the index goes out with every
// ping, delete requests come back in its reply. See CacheSync in
// Shared/Stores.swift.
function approxCacheBytes(key, value) {
  try { return new Blob([key + JSON.stringify(value)]).size; } catch (e) { return 0; }
}

// One row per movieId:targetLang:sourceLang, merging the translation entry
// with its glossary and annotation entries and its title metadata (merged
// here at index time rather than at write time, which is what avoids a
// write-ordering race with the jobs' own cache writes).
function buildCacheIndex(all) {
  const groups = {};
  function groupFor(rest) {
    if (!groups[rest]) {
      const [movieId, targetLang, sourceLang] = rest.split(':');
      groups[rest] = {
        movieId: movieId, targetLang: targetLang, sourceLang: sourceLang,
        lineCount: 0, bytes: 0, savedAt: 0, seriesTitle: null, episodeTitle: null, seasonNumber: null,
        hasTranslation: false
      };
    }
    return groups[rest];
  }
  for (const key of Object.keys(all)) {
    if (key.startsWith(TITLE_META_PREFIX)) {
      const g = groupFor(key.slice(TITLE_META_PREFIX.length));
      const meta = all[key] || {};
      g.seriesTitle = meta.seriesTitle || null;
      g.episodeTitle = meta.episodeTitle || null;
      g.seasonNumber = typeof meta.seasonNumber === 'number' ? meta.seasonNumber : null;
      continue;
    }
    if (!key.startsWith(MS.CACHE_PREFIX)) continue;
    const value = all[key];
    const g = groupFor(cacheGroupOfKey(key));
    g.bytes += approxCacheBytes(key, value);
    g.savedAt = Math.max(g.savedAt, (value && value.savedAt) || 0);
    if (key.startsWith(MS.GLOSSARY_PREFIX)) continue;
    if (key.startsWith(MS.ANNOTATE_PREFIX)) {
      if (!g.hasTranslation && Array.isArray(value && value.annotations)) g.lineCount = value.annotations.length;
      continue;
    }
    g.hasTranslation = true;
    g.lineCount = Array.isArray(value && value.translations) ? value.translations.length : 0;
  }
  // A title-only group (metadata arrived but the cache entry was since
  // evicted or never written) shouldn't surface as a phantom cache row.
  return Object.values(groups)
    .filter((g) => g.bytes > 0 || g.lineCount > 0)
    .map((g) => ({
      movieId: g.movieId, targetLang: g.targetLang, sourceLang: g.sourceLang,
      lineCount: g.lineCount, bytes: g.bytes, savedAt: g.savedAt,
      seriesTitle: g.seriesTitle, episodeTitle: g.episodeTitle, seasonNumber: g.seasonNumber
    }));
}

async function syncCacheIndex() {
  try {
    return buildCacheIndex(await api.storage.local.get(null));
  } catch (e) {
    return [];
  }
}

// Applies a delete request the app queued (`cacheDeleteRequest` in the ping
// reply), rebuilding the storage.local keys from the movieId/targetLang/
// sourceLang tuple, which is all the app knows about them.
async function applyCacheDeleteRequest(req) {
  if (!req) return;
  try {
    if (req.clearAll) {
      const all = await api.storage.local.get(null);
      const keys = Object.keys(all).filter((k) => k.startsWith(MS.CACHE_PREFIX) || k.startsWith(TITLE_META_PREFIX));
      if (keys.length) await api.storage.local.remove(keys);
      return;
    }
    if (Array.isArray(req.groups) && req.groups.length) {
      const keys = [];
      for (const g of req.groups) {
        keys.push(
          MS.translateKey(g.movieId, g.targetLang, g.sourceLang),
          MS.glossaryKey(g.movieId, g.targetLang, g.sourceLang),
          MS.annotateKey(g.movieId, g.targetLang, g.sourceLang),
          TITLE_META_PREFIX + MS.cacheGroup(g.movieId, g.targetLang, g.sourceLang)
        );
      }
      await api.storage.local.remove(keys);
    }
  } catch (e) { dbg('applyCacheDeleteRequest failed:', String(e && e.message || e)); }
}

async function pingNative() {
  const cacheIndex = await syncCacheIndex();
  const res = await sendNative({ action: 'ping', cacheIndex: cacheIndex });
  if (res && res.ok) rememberEngine(res.engine);
  if (res && res.cacheDeleteRequest) {
    applyCacheDeleteRequest(res.cacheDeleteRequest).catch(() => {});
  }
  return res;
}

// Relays content.js's transcript to the two native calls it has no channel
// for: first landing the text (`save-transcript`), then waking the app on its
// vocabulary tab (`open-app` with destination "vocab"). If the save fails,
// there'd be nothing for the app to pick up, so don't open it.
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

// ---------------------------------------------------------------------------
// One-off requests from the popup and content scripts
// ---------------------------------------------------------------------------

// Forwarded to the native action of the same name, with only these fields.
// An API key passes through here once and is never stored or sent back to
// JavaScript (see ARCHITECTURE §3): 'set-engine' saves it natively, while
// 'test-engine' (a candidate setup, tested before anything is saved) and
// 'list-models' only use it for that one request. 'consent' records the
// user's confirmation that subtitles may go to that provider.
const NATIVE_FORWARD = {
  'get-engine-options': [],
  'set-engine': ['engine', 'provider', 'model', 'baseURL', 'apiKey', 'consent'],
  'test-engine': ['provider', 'model', 'baseURL', 'apiKey'],
  'list-models': ['provider', 'baseURL', 'apiKey'],
  'set-prefs': ['prefs']
};

function reply(sendResponse, promise) {
  promise
    .then((res) => sendResponse(res || { ok: false, error: 'empty-response' }))
    .catch((e) => sendResponse({ ok: false, error: e.code ? normalizeCode(e.code) : 'native-unavailable', detail: e.detail || '' }));
  return true; // async response
}

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || typeof msg.type !== 'string') return false;
  if (msg.type === 'ping-native') return reply(sendResponse, pingNative());
  if (msg.type === 'open-app') {
    // Wakes or launches the host app via its multisub:// URL scheme; the
    // native side defaults to the styles panel when no destination is given.
    const req = { action: 'open-app' };
    if (typeof msg.destination === 'string') req.destination = msg.destination;
    return reply(sendResponse, sendNative(req));
  }
  if (msg.type === 'organize-vocab') return reply(sendResponse, organizeVocab(msg.payload || {}));
  if (Object.prototype.hasOwnProperty.call(NATIVE_FORWARD, msg.type)) {
    const req = { action: msg.type };
    for (const field of NATIVE_FORWARD[msg.type]) {
      if (msg[field] !== undefined) req[field] = msg[field];
    }
    return reply(sendResponse, sendNative(req).then((res) => {
      if (res && res.ok && res.engine) rememberEngine(res.engine);
      return res;
    }));
  }
  return false;
});

// Everything above ran: let the real listeners answer from now on.
globalThis.__multisubBackgroundReady = true;

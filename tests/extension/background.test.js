'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const EXT = process.env.EXT || require('path').resolve(__dirname, '../../extension');

function makeEvent() {
  const listeners = [];
  return { addListener: (fn) => listeners.push(fn), listeners, fire: (...a) => listeners.map((fn) => fn(...a)) };
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Fresh background page with a scripted native side.
function boot(native, scale = 1, opts = {}) {
  const store = {};
  const storageChanged = makeEvent();
  const onConnect = makeEvent();
  const onMessage = makeEvent();
  const calls = [];
  const events = []; // [t, 'start'|'end', action]
  let inflight = 0, maxInflight = 0;
  const browser = {
    runtime: {
      id: 'test',
      onConnect, onMessage,
      async sendNativeMessage(id, msg) {
        calls.push(JSON.parse(JSON.stringify(msg)));
        events.push([Date.now(), 'start', msg.action]);
        inflight++; maxInflight = Math.max(maxInflight, inflight);
        try { return await native(msg); } finally { inflight--; events.push([Date.now(), 'end', msg.action]); }
      }
    },
    storage: {
      onChanged: storageChanged,
      local: {
        async get(key) {
          if (key == null) return JSON.parse(JSON.stringify(store));
          const out = {};
          for (const k of [].concat(key)) if (k in store) out[k] = JSON.parse(JSON.stringify(store[k]));
          return out;
        },
        async set(obj) {
          for (const k of Object.keys(obj)) {
            const oldValue = store[k];
            store[k] = JSON.parse(JSON.stringify(obj[k]));
            storageChanged.fire({ [k]: { oldValue, newValue: store[k] } }, 'local');
          }
        },
        async remove(keys) { for (const k of [].concat(keys)) delete store[k]; }
      }
    }
  };
  const timers = [];
  const ctx = vm.createContext({
    browser, console, Blob, Promise,
    // scale < 1 shortens the retry delays (2 s, 6 s) so tests can go through them.
    setTimeout: (f, ms) => setTimeout(f, ms >= 1000 ? ms * scale : ms), clearTimeout,
    setInterval: (fn, ms) => { const t = setInterval(fn, ms); t.unref(); timers.push(t); return t; },
    clearInterval
  });
  if (!opts.withoutShared) vm.runInContext(fs.readFileSync(EXT + '/shared.js', 'utf8'), ctx, { filename: 'shared.js' });
  try {
    vm.runInContext(fs.readFileSync(EXT + '/background.js', 'utf8'), ctx, { filename: 'background.js' });
  } catch (e) {
    if (!opts.withoutShared) throw e;
  }

  function connect() {
    const toBg = makeEvent(), disc = makeEvent(), posted = [], postedAt = [];
    const port = {
      name: 'multisub',
      onMessage: toBg, onDisconnect: disc,
      postMessage: (m) => { posted.push(JSON.parse(JSON.stringify(m))); postedAt.push(Date.now()); }
    };
    onConnect.fire(port);
    return {
      posted,
      timeOf: (pred) => postedAt[posted.findIndex(pred)],
      send: (m) => toBg.fire(m),
      disconnect: () => disc.fire(),
      waitFor: async (pred, ms = 3000) => {
        const end = Date.now() + ms;
        while (Date.now() < end) { const hit = posted.find(pred); if (hit) return hit; await sleep(5); }
        throw new Error('timed out waiting; posted: ' + JSON.stringify(posted.map((p) => p.type)));
      }
    };
  }
  // Like the browser: every listener sees the message, the first
  // sendResponse wins, and with no listener keeping the channel open (true)
  // the caller gets undefined.
  function request(msg) {
    return new Promise((resolve) => {
      let answered = false;
      const respond = (v) => { if (!answered) { answered = true; resolve(v); } };
      let keepOpen = false;
      for (const l of onMessage.listeners) if (l(msg, {}, respond) === true) keepOpen = true;
      if (!keepOpen) respond(undefined);
    });
  }
  return { store, calls, events, connect, request, stats: () => ({ maxInflight }), ctx };
}

const engine = (active) => ({ configured: 'auto', active, provider: 'anthropic', providerName: 'Anthropic', model: 'claude-haiku-5-5', hasKey: active === 'cloud' });
const lines = (n) => Array.from({ length: n }, (_, i) => 'line ' + i);
const starts = (n) => Array.from({ length: n }, (_, i) => i * 2);

let passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log('ok   ' + name); }
  catch (e) { console.log('FAIL ' + name + '\n     ' + (e.stack || e.message).split('\n').slice(0, 4).join('\n     ')); process.exitCode = 1; }
}

(async () => {
  await test('translate job, cloud: starts at startIndex, 3 workers, 24-line batches, caches, done', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud'), prefs: null };
      if (msg.action === 'extract-glossary') return { ok: true, glossary: {} };
      if (msg.action === 'translate') { await sleep(30); return { ok: true, translations: msg.lines.map((l) => 'T(' + l + ')') }; }
      return { ok: false, error: 'unknown-action' };
    });
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '81', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(100), referenceLines: new Array(100).fill(null), starts: starts(100), startIndex: 50 });
    await c.waitFor((m) => m.type === 'done');
    const tr = bg.calls.filter((m) => m.action === 'translate');
    assert.equal(tr.length, 5); // 24,24,24,24,4
    assert.equal(tr[0].lines[0], 'line 48'); // chunk containing 50 first
    assert.deepEqual(tr.map((m) => m.lines.length).sort((a, b) => a - b), [4, 24, 24, 24, 24]);
    assert.equal(bg.stats().maxInflight, 3);
    assert.equal(bg.calls[0].action, 'ping'); // engine info refreshed before the job
    const prog = c.posted.filter((m) => m.type === 'progress');
    assert.ok(prog.every((m) => m.kind === 'translate' && Array.isArray(m.items)));
    assert.equal(prog[0].start, 48);
    const done = c.posted.find((m) => m.type === 'done');
    assert.equal(done.kind, 'translate');
    const cached = bg.store['ms:81:zh-TW:en'];
    assert.equal(cached.v, 1);
    assert.equal(cached.translations.length, 100);
    assert.ok(cached.translations.every((t, i) => t === 'T(line ' + i + ')'));
    assert.equal(cached.targetLang, 'zh-TW');

    // Same job again: replays from cache, no translate calls.
    const before = bg.calls.length;
    const c2 = bg.connect();
    c2.send({ type: 'job', kind: 'translate', movieId: '81', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(100), referenceLines: new Array(100).fill(null), starts: starts(100), startIndex: 0 });
    const d2 = await c2.waitFor((m) => m.type === 'done');
    assert.equal(d2.fromCache, true);
    assert.equal(c2.posted[0].type, 'progress');
    assert.equal(c2.posted[0].start, 0);
    assert.equal(c2.posted[0].items.length, 100);
    assert.equal(bg.calls.slice(before).filter((m) => m.action === 'translate').length, 0);
  });

  await test('annotate job, local: one worker, scene chunks, context + reference + level, cache by level', async () => {
    let concurrent = 0, maxC = 0;
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      if (msg.action === 'annotate') {
        concurrent++; maxC = Math.max(maxC, concurrent);
        await sleep(10); concurrent--;
        return { ok: true, annotations: msg.lines.map((l, i) => (i === 0 ? [{ term: 'line', gloss: '行' }, { bad: 1 }] : [])) };
      }
      return { ok: false, error: 'unknown-action' };
    });
    const n = 40;
    const st = Array.from({ length: n }, (_, i) => (i < 10 ? i : i + 20)); // 20 s pause after cue 9
    const ref = Array.from({ length: n }, (_, i) => (i % 2 ? '參考 ' + i : null));
    const c = bg.connect();
    c.send({ type: 'job', kind: 'annotate', movieId: '82', sourceLang: 'en', targetLang: 'zh-TW', level: 'B2',
      lines: lines(n), referenceLines: ref, starts: st, startIndex: 12 });
    await c.waitFor((m) => m.type === 'done');
    const an = bg.calls.filter((m) => m.action === 'annotate');
    assert.equal(maxC, 1);
    assert.deepEqual(an.map((m) => [m.lines[0], m.lines.length]), [['line 10', 16], ['line 26', 14], ['line 0', 10]]);
    assert.deepEqual(an[0].context, ['line 8', 'line 9']);
    assert.deepEqual(an[2].context, []);
    assert.deepEqual(an[0].reference, ref.slice(10, 26));
    assert.equal(an[0].level, 'B2');
    assert.equal(an[0].sourceLang, 'en');
    assert.equal(an[0].targetLang, 'zh-TW');
    const p = c.posted.find((m) => m.type === 'progress');
    assert.equal(p.kind, 'annotate');
    assert.deepEqual(p.items[0], [{ term: 'line', gloss: '行' }]); // invalid item dropped
    const cached = bg.store['ms:an:82:zh-TW:en'];
    assert.equal(cached.v, 1);
    assert.equal(cached.level, 'B2');
    assert.equal(cached.annotations.length, n);
    assert.ok(cached.annotations.every((a) => Array.isArray(a)));
    assert.ok(!('ms:82:zh-TW:en' in bg.store)); // translate cache untouched

    // Different level: cache miss, re-annotates.
    const before = bg.calls.filter((m) => m.action === 'annotate').length;
    const c2 = bg.connect();
    c2.send({ type: 'job', kind: 'annotate', movieId: '82', sourceLang: 'en', targetLang: 'zh-TW', level: 'A2',
      lines: lines(n), referenceLines: ref, starts: st, startIndex: 0 });
    const d = await c2.waitFor((m) => m.type === 'done');
    assert.ok(!d.fromCache);
    assert.equal(bg.calls.filter((m) => m.action === 'annotate').length - before, 3);
    assert.equal(bg.store['ms:an:82:zh-TW:en'].level, 'A2');

    // Cache index groups the annotate entry with title metadata.
    await bg.request({ type: 'episode-title' }); // not a runtime message: ignored
    c2.send({ type: 'episode-title', movieId: '82', sourceLang: 'en', targetLang: 'zh-TW', seriesTitle: 'Show', episodeTitle: 'Ep', seasonNumber: 2 });
    await sleep(20);
    await bg.request({ type: 'ping-native' });
    const ping = bg.calls.filter((m) => m.action === 'ping').pop();
    const row = ping.cacheIndex.find((g) => g.movieId === '82');
    assert.equal(row.lineCount, n);
    assert.equal(row.seriesTitle, 'Show');
    assert.equal(row.seasonNumber, 2);
    assert.ok(row.bytes > 0);
    assert.ok(!('hasTranslation' in row));
  });

  await test('prioritize moves the chunk containing index to the front (local engine)', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      if (msg.action === 'translate') { await sleep(40); return { ok: true, translations: msg.lines.map(() => 'x') }; }
      if (msg.action === 'extract-glossary') return { ok: true, glossary: {} };
      return { ok: false };
    });
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '83', sourceLang: 'en', targetLang: 'ja',
      lines: lines(120), referenceLines: new Array(120).fill(null), starts: starts(120), startIndex: 0 });
    await sleep(15); // first chunk [0,12) in flight
    c.send({ type: 'prioritize', kind: 'translate', movieId: '83', index: 77 });
    await c.waitFor((m) => m.type === 'done', 8000);
    const order = bg.calls.filter((m) => m.action === 'translate').map((m) => m.lines[0]);
    assert.deepEqual(order.slice(0, 3), ['line 0', 'line 72', 'line 84']);
    assert.equal(order.length, 10);
  });

  await test('fatal error stops the job and reports kind/code/detail; transient errors are retried', async () => {
    let n = 0;
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'translate') { n++; return { ok: false, error: 'auth-failed', detail: '401 invalid x-api-key' }; }
      return { ok: true, glossary: {} };
    });
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '84', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(100), referenceLines: null, starts: starts(100), startIndex: 0 });
    const err = await c.waitFor((m) => m.type === 'error');
    assert.deepEqual(err, { type: 'error', kind: 'translate', code: 'auth-failed', detail: '401 invalid x-api-key' });
    await sleep(50);
    assert.ok(n <= 3, 'stopped after the in-flight chunks, got ' + n);
    assert.ok(!c.posted.some((m) => m.type === 'done'));

    let attempts = 0;
    const bg2 = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      if (msg.action === 'annotate') {
        attempts++;
        if (attempts === 1) return { ok: false, error: 'rate-limited' };
        return { ok: true, annotations: msg.lines.map(() => []) };
      }
      return { ok: false };
    });
    const c2 = bg2.connect();
    c2.send({ type: 'job', kind: 'annotate', movieId: '85', sourceLang: 'en', targetLang: 'zh-TW', level: 'B1',
      lines: lines(5), referenceLines: null, starts: starts(5), startIndex: 0 });
    await c2.waitFor((m) => m.type === 'done', 5000);
    assert.equal(attempts, 2);

    // Legacy free-form native errors map to provider-error.
    const bg3 = boot(async (msg) => (msg.action === 'ping' ? { ok: true, engine: engine('local') }
      : { ok: false, error: 'translate-failed: boom' }));
    const c3 = bg3.connect();
    c3.send({ type: 'job', kind: 'translate', movieId: '86', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(3), referenceLines: null, starts: starts(3), startIndex: 0 });
    const e3 = await c3.waitFor((m) => m.type === 'error', 15000);
    assert.equal(e3.code, 'provider-error');
    assert.equal(e3.detail, 'translate-failed: boom');
  });

  await test('native unreachable -> native-unavailable', async () => {
    const bg = boot(async () => { throw new Error('Native messaging host not found'); });
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '87', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(3), referenceLines: null, starts: starts(3), startIndex: 0 });
    const e = await c.waitFor((m) => m.type === 'error');
    assert.equal(e.code, 'native-unavailable');
    const res = await bg.request({ type: 'ping-native' });
    assert.equal(res.ok, false);
    assert.equal(res.error, 'native-unavailable');
  });

  await test('port disconnect cancels the job; a new job on the same port supersedes the old one', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      if (msg.action === 'translate' || msg.action === 'annotate') {
        await sleep(30);
        return msg.action === 'translate' ? { ok: true, translations: msg.lines.map(() => 'x') } : { ok: true, annotations: msg.lines.map(() => []) };
      }
      return { ok: true, glossary: {} };
    });
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '88', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(120), referenceLines: null, starts: starts(120), startIndex: 0 });
    await sleep(45);
    c.disconnect();
    await sleep(150);
    const count = bg.calls.filter((m) => m.action === 'translate').length;
    assert.ok(count <= 2, 'expected the loop to stop, saw ' + count + ' calls');

    const c2 = bg.connect();
    c2.send({ type: 'job', kind: 'translate', movieId: '89', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(120), referenceLines: null, starts: starts(120), startIndex: 0 });
    await sleep(45);
    c2.send({ type: 'job', kind: 'annotate', movieId: '89', sourceLang: 'en', targetLang: 'zh-TW', level: 'B1',
      lines: lines(20), referenceLines: null, starts: starts(20), startIndex: 0 });
    await c2.waitFor((m) => m.type === 'done' && m.kind === 'annotate', 5000);
    const tr89 = bg.calls.filter((m) => m.action === 'translate').length - count;
    assert.ok(tr89 <= 2, 'old translate job should stop, saw ' + tr89);
    assert.ok(!c2.posted.some((m) => m.type === 'done' && m.kind === 'translate'));
  });

  await test('line jobs for both kinds, with LRU', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'translate') return { ok: true, translations: ['你好'] };
      if (msg.action === 'annotate') return { ok: true, annotations: [[{ term: 'adamant', gloss: '堅決' }]] };
      return { ok: false };
    });
    const c = bg.connect();
    c.send({ type: 'line', kind: 'translate', text: 'Hello', targetLang: 'zh-TW' });
    c.send({ type: 'line', kind: 'annotate', text: 'He was adamant.', targetLang: 'zh-TW', level: 'B1', sourceLang: 'en' });
    await c.waitFor((m) => m.type === 'line-result' && m.kind === 'annotate');
    await c.waitFor((m) => m.type === 'line-result' && m.kind === 'translate');
    assert.deepEqual(c.posted.find((m) => m.kind === 'translate'), { type: 'line-result', kind: 'translate', text: 'Hello', result: '你好' });
    assert.deepEqual(c.posted.find((m) => m.kind === 'annotate').result, [{ term: 'adamant', gloss: '堅決' }]);
    const annCall = bg.calls.find((m) => m.action === 'annotate');
    assert.deepEqual(annCall, { action: 'annotate', lines: ['He was adamant.'], context: [], reference: [null], sourceLang: 'en', targetLang: 'zh-TW', level: 'B1' });
    c.send({ type: 'line', kind: 'translate', text: 'Hello', targetLang: 'zh-TW' });
    await sleep(20);
    assert.equal(bg.calls.filter((m) => m.action === 'translate').length, 1);
    assert.equal(c.posted.filter((m) => m.kind === 'translate').length, 2);

    const bgErr = boot(async () => ({ ok: false, error: 'engine-not-ready' }));
    const ce = bgErr.connect();
    ce.send({ type: 'line', kind: 'annotate', text: 'x', targetLang: 'zh-TW', level: 'B1' });
    const r = await ce.waitFor((m) => m.type === 'line-result');
    assert.deepEqual(r, { type: 'line-result', kind: 'annotate', text: 'x', code: 'engine-not-ready' });
  });

  await test('popup/content requests are forwarded to native with only their fields', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'set-engine') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'test-engine') return { ok: true, latencyMs: 912, sample: '你好' };
      if (msg.action === 'get-engine-options') return { ok: true, providers: [{ id: 'anthropic' }], engine: engine(null) };
      if (msg.action === 'list-models') return { ok: true, models: ['a', 'b'] };
      if (msg.action === 'set-prefs') return { ok: true };
      if (msg.action === 'open-app') return { ok: true };
      return { ok: false, error: 'unknown-action' };
    });
    const r1 = await bg.request({ type: 'set-engine', engine: 'cloud', provider: 'anthropic', model: 'claude-haiku-5-5', apiKey: 'sk-test', junk: 1 });
    assert.equal(r1.ok, true);
    assert.deepEqual(bg.calls[0], { action: 'set-engine', engine: 'cloud', provider: 'anthropic', model: 'claude-haiku-5-5', apiKey: 'sk-test' });
    assert.equal((await bg.request({ type: 'test-engine' })).latencyMs, 912);
    assert.deepEqual(bg.calls[1], { action: 'test-engine' });
    await bg.request({ type: 'list-models', provider: 'openai' });
    assert.deepEqual(bg.calls[2], { action: 'list-models', provider: 'openai' });
    await bg.request({ type: 'get-engine-options' });
    const prefs = { mode: 'annotate', targetLang: 'zh-TW', annotateLevel: 'B1', updatedAt: 5 };
    await bg.request({ type: 'set-prefs', prefs });
    assert.deepEqual(bg.calls[4], { action: 'set-prefs', prefs });
    await bg.request({ type: 'open-app', destination: 'engine' });
    assert.deepEqual(bg.calls[5], { action: 'open-app', destination: 'engine' });
    await bg.request({ type: 'open-app' });
    assert.deepEqual(bg.calls[6], { action: 'open-app' });
    assert.equal(await bg.request({ type: 'nope' }), undefined);
  });

  await test('整理本集單字: stages the transcript, then opens the app on vocab; vocab-status forwards only movieId', async () => {
    let saveReply = { ok: true };
    const bg = boot(async (msg) => {
      if (msg.action === 'save-transcript') return saveReply;
      if (msg.action === 'open-app') return { ok: true };
      if (msg.action === 'vocab-status') return { ok: true, movieId: msg.movieId, state: 'running', accepted: true, done: 3, total: 12 };
      return { ok: false, error: 'unknown-action' };
    });
    const payload = { movieId: '81', seriesTitle: 'Show', episodeTitle: 'Pilot', seasonNumber: 1, sourceLang: 'en', targetLang: 'zh-TW', lines: ['a', 'b'] };
    assert.deepEqual(await bg.request({ type: 'organize-vocab', payload }), { ok: true });
    assert.deepEqual(bg.calls, [
      Object.assign({ action: 'save-transcript' }, payload),
      { action: 'open-app', destination: 'vocab', movieId: '81' }
    ]);
    const st = await bg.request({ type: 'vocab-status', movieId: '81', lines: ['x'], junk: 1 });
    assert.deepEqual(bg.calls[2], { action: 'vocab-status', movieId: '81' });
    assert.deepEqual(st, { ok: true, movieId: '81', state: 'running', accepted: true, done: 3, total: 12 });
    // A failed save opens nothing: there'd be no transcript for the app.
    saveReply = { ok: false, error: 'bad-request' };
    assert.deepEqual(await bg.request({ type: 'organize-vocab', payload }), { ok: false, error: 'bad-request' });
    assert.deepEqual(bg.calls.slice(3).map((c) => c.action), ['save-transcript']);
    // Native unreachable: the popup gets a code it can show.
    const down = boot(async () => { throw new Error('no app'); });
    const res = await down.request({ type: 'vocab-status', movieId: '81' });
    assert.equal(res.ok, false);
    assert.equal(res.error, 'native-unavailable');
  });

  await test('disabling MultiSub stops jobs and unloads the model', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      if (msg.action === 'translate') { await sleep(30); return { ok: true, translations: msg.lines.map(() => 'x') }; }
      return { ok: true, glossary: {} };
    });
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '90', sourceLang: 'en', targetLang: 'zh-TW',
      lines: lines(120), referenceLines: null, starts: starts(120), startIndex: 0 });
    await sleep(40);
    await bg.ctx.browser.storage.local.set({ settings: { enabled: true } });
    await bg.ctx.browser.storage.local.set({ settings: { enabled: false } });
    await sleep(120);
    assert.ok(bg.calls.some((m) => m.action === 'unload'));
    assert.ok(bg.calls.filter((m) => m.action === 'translate').length <= 2);
  });

  await test('legacy translate cache entries stay valid; pruneCache keeps v1 entries of every kind', async () => {
    const bg = boot(async (msg) => (msg.action === 'ping' ? { ok: true, engine: engine('local') } : { ok: false }));
    bg.store['ms:91:zh-TW:en'] = { v: 1, translations: ['甲', '乙'], savedAt: 1, targetLang: 'zh-TW', sourceLang: 'en' };
    bg.store['ms:0:zh-TW:en'] = { translations: ['old schema'] };
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '91', sourceLang: 'en', targetLang: 'zh-TW',
      lines: ['a', 'b'], referenceLines: null, starts: [0, 1], startIndex: 0 });
    const d = await c.waitFor((m) => m.type === 'done');
    assert.equal(d.fromCache, true);
    assert.deepEqual(c.posted[0].items, ['甲', '乙']);
  });


  const job = (movieId, n, extra) => Object.assign({ type: 'job', kind: 'translate', movieId, sourceLang: 'en', targetLang: 'zh-TW',
    lines: lines(n), referenceLines: null, starts: starts(n), startIndex: 0 }, extra || {});

  await test('a chunk that keeps failing (non-fatal) is skipped: left null, counted, done{partial}; the next job redoes only it', async () => {
    let fixed = false;
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'translate') {
        await sleep(5);
        if (msg.lines[0] === 'line 24' && !fixed) return { ok: false, error: 'provider-error', detail: 'HTTP 400 context length exceeded' };
        return { ok: true, translations: msg.lines.map((l) => 'T(' + l + ')') };
      }
      return { ok: false };
    }, 0.01);
    const c = bg.connect();
    c.send(job('92', 100));
    const done = await c.waitFor((m) => m.type === 'done');
    assert.deepEqual(done, { type: 'done', kind: 'translate', partial: true, missing: 24, code: 'provider-error' });
    assert.ok(!c.posted.some((m) => m.type === 'error'));
    const bad = bg.calls.filter((m) => m.action === 'translate' && m.lines[0] === 'line 24');
    assert.equal(bad.length, 3); // first try + 2 retries
    const cached = bg.store['ms:92:zh-TW:en'].translations;
    assert.ok(cached.slice(24, 48).every((t) => t === null)); // never cached as ''
    assert.ok(cached.slice(0, 24).concat(cached.slice(48)).every((t) => typeof t === 'string' && t.startsWith('T(')));

    fixed = true;
    const before = bg.calls.length;
    const c2 = bg.connect();
    c2.send(job('92', 100));
    const d2 = await c2.waitFor((m) => m.type === 'done');
    assert.ok(!d2.partial && !d2.fromCache);
    const redo = bg.calls.slice(before).filter((m) => m.action === 'translate');
    assert.deepEqual(redo.map((m) => m.lines[0]), ['line 24']);
    assert.ok(bg.store['ms:92:zh-TW:en'].translations.every((t) => typeof t === 'string'));
  });

  await test('several chunks failing in a row abort the job with that code; a lone failing job is an error, not partial', async () => {
    const bg = boot(async (msg) => (msg.action === 'ping' ? { ok: true, engine: engine('local') }
      : { ok: false, error: 'network', detail: 'offline' }), 0.01);
    const c = bg.connect();
    c.send(job('93', 120));
    const e = await c.waitFor((m) => m.type === 'error');
    assert.equal(e.code, 'network');
    const tr = bg.calls.filter((m) => m.action === 'translate');
    assert.equal(tr.length, 9); // 3 chunks x (1 + 2 retries), then stop (local: one worker)
    assert.ok(!c.posted.some((m) => m.type === 'done'));
  });

  await test('fatal codes (consent-required, engine-not-ready, auth-failed …) stop at once, no retries', async () => {
    for (const code of ['consent-required', 'engine-not-ready', 'model-not-ready', 'auth-failed']) {
      const bg = boot(async (msg) => (msg.action === 'ping' ? { ok: true, engine: engine('local') } : { ok: false, error: code }));
      const c = bg.connect();
      c.send(job('94', 60));
      const e = await c.waitFor((m) => m.type === 'error');
      assert.equal(e.code, code);
      assert.equal(bg.calls.filter((m) => m.action === 'translate').length, 1, code);
    }
  });

  await test('glossary extraction stops when its job ends (done or failed)', async () => {
    const n = 400;
    const ref = Array.from({ length: n }, (_, i) => '參考 ' + i);
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'extract-glossary') { await sleep(60); return { ok: true, glossary: { Alice: '愛麗絲' } }; }
      if (msg.action === 'translate') { await sleep(5); return { ok: true, translations: msg.lines.map(() => 'x') }; }
      return { ok: false };
    });
    const c = bg.connect();
    c.send(job('95', n, { referenceLines: ref }));
    await c.waitFor((m) => m.type === 'done');
    const doneAt = c.timeOf((m) => m.type === 'done');
    await sleep(250);
    const startedAfter = bg.events.filter(([t, kind, a]) => kind === 'start' && a === 'extract-glossary' && t > doneAt + 1);
    assert.equal(startedAfter.length, 0, 'extract-glossary calls after done: ' + startedAfter.length);
    assert.ok(bg.calls.filter((m) => m.action === 'extract-glossary').length < 10);

    const bg2 = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'extract-glossary') { await sleep(40); return { ok: true, glossary: {} }; }
      return { ok: false, error: 'auth-failed' };
    });
    const c2 = bg2.connect();
    c2.send(job('96', n, { referenceLines: ref }));
    await c2.waitFor((m) => m.type === 'error');
    const failedAt = c2.timeOf((m) => m.type === 'error');
    await sleep(200);
    assert.equal(bg2.events.filter(([t, kind, a]) => kind === 'start' && a === 'extract-glossary' && t > failedAt + 1).length, 0);
  });

  await test('local engine: the glossary starts only after the first batch is back', async () => {
    const n = 60;
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      if (msg.action === 'extract-glossary') { await sleep(5); return { ok: true, glossary: {} }; }
      if (msg.action === 'translate') { await sleep(30); return { ok: true, translations: msg.lines.map(() => 'x') }; }
      return { ok: false };
    });
    const c = bg.connect();
    c.send(job('97', n, { referenceLines: Array.from({ length: n }, (_, i) => 'r' + i) }));
    await c.waitFor((m) => m.type === 'done');
    const firstTranslateEnd = bg.events.find(([, k, a]) => k === 'end' && a === 'translate')[0];
    const firstGlossaryStart = bg.events.find(([, k, a]) => k === 'start' && a === 'extract-glossary')[0];
    assert.ok(firstGlossaryStart >= firstTranslateEnd, 'glossary started before the first batch returned');
    const order = bg.events.filter(([, k]) => k === 'start').map(([, , a]) => a).filter((a) => a !== 'ping');
    assert.equal(order[0], 'translate');
    assert.ok(order.includes('extract-glossary'));

    // cloud keeps sending it alongside the first batches
    const bg2 = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'extract-glossary') return { ok: true, glossary: {} };
      await sleep(30); return { ok: true, translations: msg.lines.map(() => 'x') };
    });
    const c2 = bg2.connect();
    c2.send(job('98', n, { referenceLines: Array.from({ length: n }, (_, i) => 'r' + i) }));
    await c2.waitFor((m) => m.type === 'done');
    const g = bg2.events.find(([, k, a]) => k === 'start' && a === 'extract-glossary')[0];
    const t = bg2.events.find(([, k, a]) => k === 'end' && a === 'translate')[0];
    assert.ok(g < t);
  });

  await test('DOM-fallback lines on the local engine: one native call at a time, newest waiting line kept', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      if (msg.action === 'translate') { await sleep(40); return { ok: true, translations: ['譯:' + msg.lines[0]] }; }
      return { ok: false };
    });
    await bg.request({ type: 'ping-native' }); // engine info: local
    const c = bg.connect();
    c.send({ type: 'line', kind: 'translate', text: 'A', targetLang: 'zh-TW' });
    c.send({ type: 'line', kind: 'translate', text: 'B', targetLang: 'zh-TW' });
    c.send({ type: 'line', kind: 'translate', text: 'C', targetLang: 'zh-TW' });
    await c.waitFor((m) => m.type === 'line-result' && m.text === 'C' && m.result);
    assert.equal(bg.stats().maxInflight, 1);
    assert.deepEqual(bg.calls.filter((m) => m.action === 'translate').map((m) => m.lines[0]), ['A', 'C']);
    assert.deepEqual(c.posted.find((m) => m.text === 'B'), { type: 'line-result', kind: 'translate', text: 'B', dropped: true });
    assert.equal(c.posted.find((m) => m.text === 'A').result, '譯:A');

    // cloud: no gate
    const bg2 = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      await sleep(30); return { ok: true, translations: ['x'] };
    });
    await bg2.request({ type: 'ping-native' });
    const c2 = bg2.connect();
    for (const t of ['A', 'B', 'C']) c2.send({ type: 'line', kind: 'translate', text: t, targetLang: 'zh-TW' });
    await c2.waitFor((m) => m.type === 'line-result' && m.text === 'C');
    await c2.waitFor((m) => m.type === 'line-result' && m.text === 'B');
    assert.equal(bg2.stats().maxInflight, 3);
  });

  await test('a second tab with the same job shares it (no duplicate calls); the first tab keeps getting progress and done', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'translate') { await sleep(25); return { ok: true, translations: msg.lines.map((l) => 'T(' + l + ')') }; }
      return { ok: false };
    });
    const a = bg.connect();
    a.send(job('99', 240));
    await sleep(40);
    const b = bg.connect();
    b.send(job('99', 240, { startIndex: 200 }));
    await b.waitFor((m) => m.type === 'done');
    await a.waitFor((m) => m.type === 'done');
    const tr = bg.calls.filter((m) => m.action === 'translate');
    assert.equal(tr.length, 10); // 240 / 24, each chunk once
    assert.equal(new Set(tr.map((m) => m.lines[0])).size, 10);
    assert.equal(b.posted[0].type, 'progress'); // replay of what A already had
    assert.equal(b.posted[0].start, 0);
    // A saw every chunk, B every chunk after joining
    const covered = (port) => { const got = new Array(240).fill(false); for (const m of port.posted) if (m.type === 'progress') m.items.forEach((x, i) => { if (x != null) got[m.start + i] = true; }); return got.every(Boolean); };
    assert.ok(covered(a) && covered(b));

    // The first tab leaving doesn't stop the job for the second one.
    const bg2 = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      await sleep(20); return { ok: true, translations: msg.lines.map(() => 'x') };
    });
    const a2 = bg2.connect();
    a2.send(job('100', 60));
    await sleep(30);
    const b2 = bg2.connect();
    b2.send(job('100', 60));
    await sleep(10);
    a2.disconnect();
    await b2.waitFor((m) => m.type === 'done', 5000);
    assert.equal(bg2.calls.filter((m) => m.action === 'translate').length, 5);
    // ...but when the last one leaves, it stops
    const c3 = bg2.connect();
    c3.send(job('101', 120));
    await sleep(30);
    c3.disconnect();
    await sleep(150);
    assert.ok(bg2.calls.filter((m) => m.action === 'translate' && m.lines[0].startsWith('line')).length <= 5 + 2);
  });

  await test('a different job for the same key replaces the running one and tells its tab (superseded)', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('local') };
      await sleep(30); return { ok: true, translations: msg.lines.map(() => 'x') };
    });
    const a = bg.connect();
    a.send(job('102', 60));
    await sleep(40);
    const b = bg.connect();
    b.send(job('102', 60, { lines: lines(60).map((l) => l + ' (CC)') }));
    const sup = await a.waitFor((m) => m.type === 'superseded');
    assert.deepEqual(sup, { type: 'superseded', kind: 'translate' });
    await b.waitFor((m) => m.type === 'done', 5000);
    assert.ok(!a.posted.some((m) => m.type === 'done' || m.type === 'error'));

    // A job that already failed keeps its tab: it gets the error, not 'superseded'.
    // (cloud: the other two workers are still busy when the first one fails,
    // so the failed job hasn't ended yet when the second tab's job arrives)
    let calls = 0;
    const bg2 = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud') };
      if (msg.action === 'extract-glossary') return { ok: true, glossary: {} };
      calls++;
      if (calls === 1) { await sleep(5); return { ok: false, error: 'auth-failed' }; }
      await sleep(150);
      return { ok: true, translations: msg.lines.map(() => 'x') };
    });
    const a2 = bg2.connect();
    a2.send(job('103', 72));
    await sleep(40);
    const b2 = bg2.connect();
    assert.ok(!a2.posted.some((m) => m.type === 'error')); // failed, not ended yet
    b2.send(job('103', 72, { lines: lines(72).map((l) => l + '!') }));
    const e2 = await a2.waitFor((m) => m.type === 'error' || m.type === 'superseded');
    assert.equal(e2.type, 'error');
    assert.equal(e2.code, 'auth-failed');
  });

  await test('engine requests: transient key for list-models/test-engine, consent for set-engine', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'list-models') return { ok: true, models: ['m1'] };
      if (msg.action === 'test-engine') return { ok: true, latencyMs: 500, sample: '你好' };
      if (msg.action === 'set-engine') return msg.consent ? { ok: true, engine: engine('cloud') } : { ok: false, error: 'consent-required' };
      return { ok: false };
    });
    await bg.request({ type: 'list-models', provider: 'openai', apiKey: 'sk-typed', junk: 1 });
    assert.deepEqual(bg.calls[0], { action: 'list-models', provider: 'openai', apiKey: 'sk-typed' });
    const t = await bg.request({ type: 'test-engine', provider: 'custom', model: 'qwen', baseURL: 'http://localhost:1234/v1', apiKey: 'k', engine: 'cloud' });
    assert.equal(t.latencyMs, 500);
    assert.deepEqual(bg.calls[1], { action: 'test-engine', provider: 'custom', model: 'qwen', baseURL: 'http://localhost:1234/v1', apiKey: 'k' });
    const r1 = await bg.request({ type: 'set-engine', engine: 'cloud', provider: 'openai', model: 'gpt-6-luna' });
    assert.deepEqual(r1, { ok: false, error: 'consent-required' });
    const r2 = await bg.request({ type: 'set-engine', engine: 'cloud', provider: 'openai', model: 'gpt-6-luna', consent: true });
    assert.equal(r2.ok, true);
    assert.deepEqual(bg.calls[3], { action: 'set-engine', engine: 'cloud', provider: 'openai', model: 'gpt-6-luna', consent: true });
  });

  await test('refused lines (empty translation) stay null in memory and cache; not a partial job; asked again later', async () => {
    const bg = boot(async (msg) => {
      if (msg.action === 'ping') return { ok: true, engine: engine('cloud'), prefs: null };
      if (msg.action === 'translate') {
        await sleep(5);
        return { ok: true, translations: msg.lines.map((l) => (l === 'line 3' || l === 'blocked' ? '' : l === '' ? '' : 'T(' + l + ')')) };
      }
      return { ok: false };
    });
    const src = lines(10); src[5] = '';
    const c = bg.connect();
    c.send({ type: 'job', kind: 'translate', movieId: '95', sourceLang: 'en', targetLang: 'zh-TW',
      lines: src, referenceLines: null, starts: starts(10), startIndex: 0 });
    const done = await c.waitFor((m) => m.type === 'done');
    assert.ok(!done.partial, 'a refused line is not a failed chunk');
    const cached = bg.store['ms:95:zh-TW:en'].translations;
    assert.equal(cached[3], null);
    assert.equal(cached[5], ''); // an empty source line is legitimately empty
    assert.equal(cached[4], 'T(line 4)');
    const before = bg.calls.filter((m) => m.action === 'translate').length;
    const c2 = bg.connect();
    c2.send({ type: 'job', kind: 'translate', movieId: '95', sourceLang: 'en', targetLang: 'zh-TW',
      lines: src, referenceLines: null, starts: starts(10), startIndex: 0 });
    await c2.waitFor((m) => m.type === 'done');
    assert.equal(bg.calls.filter((m) => m.action === 'translate').length, before + 1, 'the chunk with the refused line is asked again');

    c.send({ type: 'line', kind: 'translate', text: 'blocked', targetLang: 'zh-TW' });
    await c.waitFor((m) => m.type === 'line-result' && m.text === 'blocked');
    c.send({ type: 'line', kind: 'translate', text: 'blocked', targetLang: 'zh-TW' });
    await sleep(40);
    assert.equal(bg.calls.filter((m) => m.action === 'translate' && m.lines[0] === 'blocked').length, 2, "'' is not kept in the line cache");
  });

  await test('boot diagnostics: with shared.js missing, the popup learns why instead of getting no answer', async () => {
    const broken = boot(async () => ({ ok: true }), 1, { withoutShared: true });
    const res = await broken.request({ type: 'ping-native' });
    assert.equal(res && res.ok, false);
    assert.equal(res.error, 'native-unavailable');
    assert.match(res.detail, /shared\.js did not load/);
    assert.equal(broken.calls.length, 0, 'nothing reached native');
    // A healthy page: the diagnostics responder stays silent and the real one answers.
    const ok = boot(async (m) => (m.action === 'ping' ? { ok: true, engine: engine('cloud') } : { ok: true }));
    const pong = await ok.request({ type: 'ping-native' });
    assert.equal(pong.ok, true);
  });

  console.log('\n' + passed + ' tests passed' + (process.exitCode ? ', some FAILED' : ''));
  process.exit(process.exitCode || 0);
})();

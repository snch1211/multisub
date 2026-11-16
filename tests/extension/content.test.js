'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const EXT = process.env.EXT || require('path').resolve(__dirname, '../../extension');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- minimal fake DOM ------------------------------------------------------
class ClassList {
  constructor() { this.set = new Set(); }
  toggle(c, on) { if (on === undefined) on = !this.set.has(c); on ? this.set.add(c) : this.set.delete(c); return on; }
  add(c) { this.set.add(c); } remove(c) { this.set.delete(c); } contains(c) { return this.set.has(c); }
}
class Node {
  constructor(tag) {
    this.nodeName = tag.toUpperCase(); this.tagName = this.nodeName; this.nodeType = 1;
    this.childNodes = []; this.parentElement = null; this.listeners = {};
    this.style = { setProperty: (k, v) => { this.style[k] = v; }, cssText: '' };
    this.classList = new ClassList(); this.attrs = {}; this.dataset = {}; this.id = '';
  }
  get className() { return [...this.classList.set].join(' '); }
  set className(v) { this.classList = new ClassList(); String(v).split(/\s+/).filter(Boolean).forEach((c) => this.classList.add(c)); }
  get children() { return this.childNodes.filter((c) => c.nodeType === 1); }
  appendChild(n) { if (n.parentElement) n.remove(); this.childNodes.push(n); n.parentElement = this; return n; }
  append(...ns) { ns.forEach((n) => this.appendChild(n)); }
  remove() { const p = this.parentElement; if (p) { p.childNodes = p.childNodes.filter((c) => c !== this); this.parentElement = null; } }
  get textContent() { return this.childNodes.map((c) => (c.nodeType === 3 ? c.nodeValue : c.textContent)).join(''); }
  set textContent(v) { this.childNodes.forEach((c) => { c.parentElement = null; }); this.childNodes = []; if (v) this.appendChild(new Text(String(v))); }
  addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
  dispatch(t, ev = {}) { ev.stopPropagation = () => {}; ev.preventDefault = () => {}; (this.listeners[t] || []).forEach((fn) => fn(ev)); }
  setAttribute(k, v) { this.attrs[k] = String(v); } getAttribute(k) { return this.attrs[k]; }
  attachShadow() { this.shadowRoot = new Node('#shadow'); this.shadowRoot.activeElement = null; return this.shadowRoot; }
  closest(sel) { let n = this; while (n) { if (matches(n, sel)) return n; n = n.parentElement; } return null; }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  querySelectorAll(sel) { const out = []; (function walk(n) { for (const c of n.childNodes) { if (c.nodeType === 1) { if (matches(c, sel)) out.push(c); walk(c); } } })(this); return out; }
  getBoundingClientRect() { return { height: 500, width: 900 }; }
  focus() {} setPointerCapture() {}
}
class Text { constructor(v) { this.nodeType = 3; this.nodeValue = v; this.nodeName = '#text'; } remove() {} }
function matches(n, sel) {
  if (n.nodeType !== 1) return false;
  if (sel.startsWith('.')) return n.classList.contains(sel.slice(1));
  if (sel.startsWith('#')) return n.id === sel.slice(1);
  return n.tagName === sel.toUpperCase();
}

function makeEvent() {
  const l = [];
  return { addListener: (f) => l.push(f), removeListener: (f) => { const i = l.indexOf(f); if (i >= 0) l.splice(i, 1); },
    l, fire: (...a) => l.slice().map((f) => f(...a)) };
}

// The watch page: the DOM and the window that every content-script instance
// on it shares (two instances when the extension was reloaded under it).
function makePage(path) {
  const html = new Node('html'); const head = new Node('head'); const body = new Node('body');
  html.append(head, body);
  const container = new Node('div'); container.classList.add('watch-video');
  const video = new Node('video'); video.currentTime = 30;
  const timedtext = new Node('div'); timedtext.classList.add('player-timedtext');
  container.append(video, timedtext); body.appendChild(container);
  const document = {
    documentElement: html, head,
    createElement: (t) => new Node(t),
    createTextNode: (v) => new Text(v),
    querySelector: (s) => html.querySelector(s),
    querySelectorAll: (s) => html.querySelectorAll(s)
  };
  const pageCommands = [];
  const winListeners = [];
  // Like the real thing, postMessage delivers asynchronously to every
  // listener on the window, whichever world added it.
  const window = {
    addEventListener: (t, f) => { if (t === 'message') winListeners.push(f); },
    removeEventListener: (t, f) => { const i = winListeners.indexOf(f); if (t === 'message' && i >= 0) winListeners.splice(i, 1); },
    postMessage: (m) => {
      if (m.__multisub_cmd) pageCommands.push(m);
      const data = JSON.parse(JSON.stringify(m));
      setImmediate(() => winListeners.slice().forEach((f) => f({ source: window, data })));
    }
  };
  window.window = window;
  const fromPage = (msg) => winListeners.slice().forEach((f) => f({ source: window, data: Object.assign({ __multisub: true }, msg) }));
  // The root element's computed custom properties (overlay.css's marker).
  const rootStyle = {};
  // overlaySheet: some version of overlay.css styles the page (its rule for
  // #multisub-overlay, z-index included, applies).
  return { html, container, video, timedtext, document, window, winListeners, pageCommands, fromPage, rootStyle,
    overlaySheet: false, location: { pathname: path } };
}

// One content-script instance (shared.js + content.js in a world of its own)
// on `page`, a new one by default. `clock` is performance.now() there.
function boot({ stored, ping, path = '/watch/81', scale = 1, extraStore = {}, navigator, page, store: sharedStore, clock }) {
  page = page || makePage(path);
  const { html, container, video, timedtext, document, window, pageCommands, fromPage } = page;
  const store = sharedStore || Object.assign({ settings: stored }, extraStore);
  const storageChanged = makeEvent();
  const onMessage = makeEvent();
  const ports = [];
  const runtimeMessages = [];
  const browser = {
    runtime: {
      id: 'x',
      getURL: (p) => 'safari-web-extension://x/' + p,
      connect: () => {
        const port = { posted: [], disconnected: false, onMessage: makeEvent(), onDisconnect: makeEvent() };
        port.postMessage = (m) => { if (port.disconnected) throw new Error('disconnected'); port.posted.push(JSON.parse(JSON.stringify(m))); };
        port.disconnect = () => { port.disconnected = true; };
        ports.push(port);
        return port;
      },
      sendMessage: async (m) => { runtimeMessages.push(m); if (m.type === 'ping-native') return ping(); return { ok: true }; },
      onMessage
    },
    storage: {
      onChanged: storageChanged,
      local: {
        get: async (k) => (store[k] !== undefined ? { [k]: JSON.parse(JSON.stringify(store[k])) } : {}),
        set: async (obj) => { for (const k of Object.keys(obj)) { const oldValue = store[k]; store[k] = JSON.parse(JSON.stringify(obj[k])); storageChanged.fire({ [k]: { oldValue, newValue: store[k] } }, 'local'); } }
      }
    }
  };
  const intervals = [];
  const locationObj = page.location;
  const ctx = vm.createContext({
    browser, window, document, console, Promise, JSON,
    // shared.js reads navigator.languages for the default second language.
    ...(navigator ? { navigator } : {}),
    ...(clock != null ? { performance: { timeOrigin: 0, now: () => clock } } : {}),
    location: locationObj,
    getComputedStyle: (el) => ({ position: 'relative',
      zIndex: el.id === 'multisub-overlay' && el.parentElement && page.overlaySheet ? '2147483000' : 'auto',
      getPropertyValue: (k) => (el === html && page.rootStyle[k] != null ? String(page.rootStyle[k]) : '') }),
    // scale < 1 shortens the long delays (retries, timeouts) so tests can
    // walk through them; the 100 ms tick and short waits stay real.
    setTimeout: (f, ms) => { const t = setTimeout(f, ms >= 1000 ? ms * scale : ms); t.unref(); return t; },
    clearTimeout,
    setInterval: (f, ms) => { const t = setInterval(f, ms); t.unref(); intervals.push(t); return t; },
    clearInterval
  });
  vm.runInContext(fs.readFileSync(EXT + '/shared.js', 'utf8'), ctx);
  vm.runInContext(fs.readFileSync(EXT + '/content.js', 'utf8'), ctx);
  const status = () => new Promise((r) => onMessage.l[0]({ type: 'get-status' }, {}, r));
  const tabMessage = (m) => new Promise((r) => { const ret = onMessage.l[0](m, {}, r); if (ret !== true && m.type !== 'get-status') {} });
  return {
    ctx, page, browser, onMessage, storageChanged,
    html, container, video, timedtext, store, ports, pageCommands, runtimeMessages, fromPage, status, tabMessage,
    navigate: (p) => { locationObj.pathname = p; },
    port: () => ports[ports.length - 1],
    overlayText: () => html.querySelector('#multisub-text'),
    overlayOriginal: () => html.querySelector('#multisub-original'),
    hint: () => html.querySelector('#multisub-hint'),
    toast: () => html.querySelector('#multisub-toast'),
    setSettings: (patch) => browser.storage.local.set({ settings: Object.assign({}, store.settings, patch) }),
    stop: () => intervals.forEach(clearInterval)
  };
}

const TRACKS = [
  { id: 'en:SUBTITLES:0', language: 'en', label: 'English', forced: false, trackType: 'SUBTITLES', format: 'webvtt' },
  { id: 'zh:CLOSEDCAPTIONS:1', language: 'zh-Hant', label: '中文（繁體）CC', forced: false, trackType: 'CLOSEDCAPTIONS', format: 'webvtt' },
  { id: 'zh:SUBTITLES:2', language: 'zh-Hant', label: '中文（繁體）', forced: false, trackType: 'SUBTITLES', format: 'webvtt' },
  { id: 'ja:SUBTITLES:3', language: 'ja', label: '日本語', forced: true, trackType: 'SUBTITLES', format: 'webvtt' }
];
const EN_CUES = Array.from({ length: 50 }, (_, i) => ({ start: i * 4, end: i * 4 + 3, text: 'line ' + i }));
const ZH_CUES = Array.from({ length: 50 }, (_, i) => ({ start: i * 4 + 0.2, end: i * 4 + 2.8, text: '第 ' + i + ' 句' }));
const cloudEngine = { configured: 'auto', active: 'cloud', provider: 'anthropic', providerName: 'Anthropic', model: 'claude-haiku-5-5', hasKey: true };
const settingsWith = (patch) => Object.assign({ enabled: true, mode: 'translate', targetLang: 'zh-TW', annotateLevel: 'B1', fontScale: 1, bottomOffset: 10, mergedMode: true, prefsUpdatedAt: 10, styles: {} }, patch);

let passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log('ok   ' + name); }
  catch (e) { console.log('FAIL ' + name + '\n     ' + (e.stack || e.message).split('\n').slice(0, 5).join('\n     ')); process.exitCode = 1; }
}

(async () => {
  await test('startup pings native right away and adopts newer native prefs', async () => {
    const t = boot({ stored: settingsWith({ mode: 'netflix', prefsUpdatedAt: 10 }),
      ping: () => ({ ok: true, engine: cloudEngine, prefs: { mode: 'annotate', targetLang: 'ja', annotateLevel: 'C1', updatedAt: 99 }, styles: { textColor: '#ffff00' } }) });
    await sleep(60);
    assert.equal(t.runtimeMessages[0].type, 'ping-native');
    assert.equal(t.store.settings.mode, 'annotate');
    assert.equal(t.store.settings.targetLang, 'ja');
    assert.equal(t.store.settings.annotateLevel, 'C1');
    assert.equal(t.store.settings.prefsUpdatedAt, 99);
    assert.equal(t.store.settings.styles.textColor, '#ffff00');
    t.stop();

    const t2 = boot({ stored: settingsWith({ mode: 'translate', prefsUpdatedAt: 500 }),
      ping: () => ({ ok: true, engine: cloudEngine, prefs: { mode: 'netflix', updatedAt: 100 } }) });
    await sleep(60);
    const push = t2.runtimeMessages.find((m) => m.type === 'set-prefs');
    assert.deepEqual(JSON.parse(JSON.stringify(push.prefs)), { mode: 'translate', targetLang: 'zh-TW', annotateLevel: 'B1', updatedAt: 500 });
    t2.stop();
  });

  await test('translate: track selection, reference, job message, rendering, seek, mode switches', async () => {
    const t = boot({ stored: settingsWith({}), ping: () => ({ ok: true, engine: cloudEngine, prefs: { updatedAt: 0 } }) });
    await sleep(150);
    assert.ok(t.pageCommands.some((c) => c.type === 'get-tracks' && c.movieId === '81'));
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'zh-Hant', displayName: '中文', audioBcp47: 'en' });
    t.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS });
    await sleep(20);
    // Netflix shows the target language, so primary falls back to the audio language (en);
    // second = zh-Hant full subtitles, not CC.
    const src = t.pageCommands.find((c) => c.type === 'fetch-track' && c.purpose === 'source');
    const ref = t.pageCommands.find((c) => c.type === 'fetch-track' && c.purpose === 'reference');
    assert.equal(src.trackId, 'en:SUBTITLES:0');
    assert.equal(ref.trackId, 'zh:SUBTITLES:2');
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    await sleep(10);
    assert.equal((await t.status()).status, 'fetching'); // waiting for the reference
    assert.equal(t.ports.length, 0);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(10);
    const job = t.port().posted.find((m) => m.type === 'job');
    assert.equal(job.kind, 'translate');
    assert.equal(job.movieId, '81');
    assert.equal(job.sourceLang, 'en');
    assert.equal(job.targetLang, 'zh-TW');
    assert.equal(job.lines.length, 50);
    assert.equal(job.referenceLines[3], '第 3 句');
    assert.equal(job.starts[3], 12);
    assert.equal(job.startIndex, 7); // currentTime 30 -> cue 7 (28..31)
    assert.ok(!('level' in job));

    // progress -> rendered
    t.port().onMessage.fire({ type: 'progress', kind: 'translate', start: 7, items: ['翻譯七', '翻譯八'] });
    await sleep(150);
    assert.equal(t.overlayText().textContent, '翻譯七');
    assert.equal(t.overlayOriginal().textContent, 'line 7'); // merged
    assert.ok(t.html.classList.contains('multisub-native-hidden'));
    // stale kind ignored
    t.port().onMessage.fire({ type: 'progress', kind: 'annotate', start: 7, items: [[{ term: 'x', gloss: 'y' }]] });
    let st = await t.status();
    assert.equal(st.translatedCount, 2);
    assert.equal(st.mode, 'translate');
    assert.equal(st.jobKind, 'translate');
    assert.equal(st.secondaryTrackFound, true);
    assert.equal(st.engineActive, 'cloud');

    // seek > 20 s -> prioritize
    t.video.currentTime = 150;
    await sleep(150);
    const pr = t.port().posted.find((m) => m.type === 'prioritize');
    assert.deepEqual(pr, { type: 'prioritize', kind: 'translate', movieId: '81', index: 37 });

    // non-merged, but Netflix draws zh-Hant (not our primary): we draw both
    // lines and hide Netflix's, instead of showing Chinese twice
    await t.setSettings({ mergedMode: false });
    t.video.currentTime = 30;
    await sleep(150);
    assert.equal(t.overlayOriginal().textContent, 'line 7');
    assert.equal(t.overlayOriginal().style.display, 'flex');
    assert.ok(t.html.classList.contains('multisub-native-hidden'));
    // Netflix switches to English (our primary): it draws the first line again
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    await sleep(150);
    assert.equal(t.overlayOriginal().style.display, 'none');
    assert.equal(t.overlayText().textContent, '翻譯七');
    assert.ok(!t.html.classList.contains('multisub-native-hidden'));
    // Netflix shows only forced narratives: not the full primary, draw it ourselves
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', forced: true, audioBcp47: 'en' });
    await sleep(150);
    assert.equal(t.overlayOriginal().style.display, 'flex');
    assert.ok(t.html.classList.contains('multisub-native-hidden'));
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    await sleep(120);

    // switch to annotate: old port closed, new job with level
    const oldPort = t.port();
    await t.setSettings({ mode: 'annotate', annotateLevel: 'B2', prefsUpdatedAt: 20 });
    await sleep(20);
    assert.ok(oldPort.disconnected);
    const aj = t.port().posted.find((m) => m.type === 'job');
    assert.equal(aj.kind, 'annotate');
    assert.equal(aj.level, 'B2');
    assert.ok(t.html.classList.contains('multisub-native-hidden')); // annotate is always merged
    // annotations render as term + gloss; plain line before they arrive
    await sleep(150);
    assert.equal(t.overlayText().textContent, 'line 7');
    assert.equal(t.overlayText().querySelectorAll('.ms-term').length, 0);
    t.port().onMessage.fire({ type: 'progress', kind: 'annotate', start: 7, items: [[{ term: 'line', gloss: '行' }]] });
    await sleep(150);
    const term = t.overlayText().querySelector('.ms-term');
    const gloss = t.overlayText().querySelector('.ms-gloss');
    assert.equal(term.textContent, 'line');
    assert.equal(gloss.textContent, '行');
    assert.equal(t.overlayOriginal().style.display, 'none');

    // done
    t.port().onMessage.fire({ type: 'done', kind: 'annotate' });
    st = await t.status();
    assert.equal(st.status, 'done');

    // switch to netflix: port closed, no job, both official lines on their own timelines
    const annPort = t.port();
    await t.setSettings({ mode: 'netflix', mergedMode: true, prefsUpdatedAt: 30 });
    await sleep(150);
    assert.ok(annPort.disconnected);
    assert.equal(t.ports.length, 2);
    assert.equal(t.overlayText().textContent, '第 7 句');
    assert.equal(t.overlayOriginal().textContent, 'line 7');
    st = await t.status();
    assert.equal(st.status, 'ready');
    assert.equal(st.jobKind, null);
    t.stop();
  });

  await test('error codes show the zh-TW hint; keepalive-free reconnect re-sends the job', async () => {
    const t = boot({ stored: settingsWith({}), ping: () => ({ ok: true, engine: cloudEngine }) });
    await sleep(150);
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    t.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS });
    await sleep(10);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t.fromPage({ type: 'track-error', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', error: 'HTTP 403' });
    await sleep(10);
    const first = t.port();
    const job = first.posted.find((m) => m.type === 'job');
    assert.ok(job.referenceLines.every((r) => r === null));
    // background unloaded: port drops while the job is unfinished -> reconnect + resend
    first.onDisconnect.fire();
    await sleep(1150);
    assert.equal(t.ports.length, 2);
    assert.equal(t.port().posted[0].type, 'job');
    t.port().onMessage.fire({ type: 'error', kind: 'translate', code: 'auth-failed', detail: '401' });
    await sleep(150);
    assert.equal(t.hint().textContent, 'MultiSub：API Key 無效或已過期，請重新貼上');
    const st = await t.status();
    assert.equal(st.status, 'error');
    assert.equal(st.errorCode, 'auth-failed');
    t.stop();
  });

  await test('netflix mode without a target-language track shows the one-time hint', async () => {
    const t = boot({ stored: settingsWith({ mode: 'netflix', targetLang: 'ko' }), ping: () => ({ ok: true, engine: null }) });
    await sleep(150);
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    t.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS });
    await sleep(10);
    assert.ok(!t.pageCommands.some((c) => c.purpose === 'reference'));
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    await sleep(150);
    assert.equal(t.hint().textContent, '這部片沒有 Netflix 官方的韓文字幕，可在 MultiSub 選單改用「AI 翻譯」');
    assert.equal(t.overlayOriginal().textContent, 'line 7');
    assert.equal(t.overlayText().style.display, 'none');
    const st = await t.status();
    assert.equal(st.secondaryTrackFound, false);
    assert.equal(t.ports.length, 0);
    t.stop();
  });

  await test('no stored settings: netflix mode by default, nothing stamped or pushed', async () => {
    const t = boot({ stored: undefined, ping: () => ({ ok: true, engine: null, prefs: { updatedAt: 0 } }) });
    await sleep(150);
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    t.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS });
    await sleep(10);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(150);
    const st = await t.status();
    assert.equal(st.mode, 'netflix');
    assert.equal(st.status, 'ready');
    assert.equal(t.overlayOriginal().textContent, 'line 7');
    assert.equal(t.overlayText().textContent, '第 7 句');
    assert.equal(t.ports.length, 0); // no AI job
    assert.equal(t.html.querySelector('#multisub-chooser'), null);
    assert.ok(!t.runtimeMessages.some((m) => m.type === 'set-prefs'));
    assert.ok(!t.store.settings || !t.store.settings.prefsUpdatedAt);
    t.stop();

    // A choice made in the app wins over the defaults; a field the app never
    // set keeps the local value.
    const t2 = boot({ stored: undefined, ping: () => ({ ok: true, engine: cloudEngine, prefs: { targetLang: 'ko', updatedAt: 7 } }) });
    await sleep(60);
    assert.equal(t2.store.settings.mode, 'netflix');
    assert.equal(t2.store.settings.targetLang, 'ko');
    assert.equal(t2.store.settings.prefsUpdatedAt, 7);
    assert.ok(!t2.runtimeMessages.some((m) => m.type === 'set-prefs'));
    t2.stop();
  });

  await test('nothing chosen yet: the default mode waits for the first ping, which may bring the app\'s choice', async () => {
    // AI 翻譯 picked in the app's onboarding, then Netflix opened from there:
    // the cues arrive before the (cold) native ping answers.
    let answer;
    const pinged = new Promise((r) => { answer = r; });
    const t = boot({ stored: undefined, navigator: { languages: ['ja-JP'] },
      ping: () => pinged.then(() => ({ ok: true, engine: cloudEngine, prefs: { mode: 'translate', targetLang: 'ja', updatedAt: 5 } })) });
    await toFetch(t);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    await sleep(150);
    let st = await t.status();
    assert.equal(st.status, 'fetching');
    assert.equal(st.secondState, 'none'); // no full Japanese track: netflix mode would hint at AI 翻譯
    assert.equal(t.overlayOriginal().style.display, 'none');
    assert.equal(t.overlayText().style.display, 'none');
    assert.equal(t.hint().textContent, '');
    assert.ok(!t.html.classList.contains('multisub-native-hidden'), "Netflix's subtitles stay up meanwhile");
    assert.equal(t.ports.length, 0);
    answer();
    await sleep(150);
    st = await t.status();
    assert.equal(st.mode, 'translate');
    assert.equal(st.status, 'translating');
    assert.equal(t.hint().textContent, '');
    assert.equal(t.ports.length, 1);
    assert.equal(t.port().posted.filter((m) => m.type === 'job').length, 1);
    assert.equal(t.port().posted[0].targetLang, 'ja');
    t.stop();

    // The app has nothing chosen either: the default mode starts once it says so.
    let answer2;
    const pinged2 = new Promise((r) => { answer2 = r; });
    const t2 = boot({ stored: undefined, ping: () => pinged2.then(() => ({ ok: true, engine: null, prefs: { updatedAt: 0 } })) });
    await toFetch(t2);
    t2.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t2.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(150);
    assert.equal(t2.overlayText().style.display, 'none');
    answer2();
    await sleep(150);
    assert.equal((await t2.status()).status, 'ready');
    assert.equal(t2.overlayOriginal().textContent, 'line 7');
    assert.equal(t2.overlayText().textContent, '第 7 句');
    assert.ok(t2.html.classList.contains('multisub-native-hidden'));
    t2.stop();

    // Something already chosen in the extension doesn't wait at all.
    const t3 = boot({ stored: settingsWith({ mode: 'netflix' }), ping: () => new Promise(() => {}) });
    await toFetch(t3);
    t3.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t3.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(150);
    assert.equal(t3.overlayText().textContent, '第 7 句');
    t3.stop();
  });

  await test('nothing chosen yet, ping never answers: the default mode runs after the wait; a late choice clears its hint', async () => {
    let answer;
    const late = new Promise((r) => { answer = r; });
    // scale 0.01: FIRST_PING_WAIT_MS (3 s) passes in 30 ms.
    const t = boot({ stored: undefined, navigator: { languages: ['ja-JP'] }, scale: 0.01,
      ping: () => late.then(() => ({ ok: true, engine: cloudEngine, prefs: { mode: 'translate', updatedAt: 5 } })) });
    await toFetch(t);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    await sleep(150);
    assert.equal((await t.status()).status, 'ready');
    assert.equal(t.overlayOriginal().textContent, 'line 7');
    assert.equal(t.hint().textContent, '這部片沒有 Netflix 官方的日文字幕，可在 MultiSub 選單改用「AI 翻譯」');
    answer();
    await sleep(150);
    const st = await t.status();
    assert.equal(st.mode, 'translate');
    assert.equal(st.status, 'translating');
    assert.equal(t.hint().textContent, '', 'the netflix-mode hint went with the mode');
    t.stop();
  });

  await test('saving with nothing chosen leaves mode, language and level out of storage', async () => {
    const t = boot({ stored: undefined, navigator: { languages: ['ja-JP'] },
      ping: () => ({ ok: true, engine: null, prefs: { updatedAt: 0 }, styles: { textColor: '#ffff00' } }) });
    await sleep(150);
    const keys = () => Object.keys(t.store.settings || {});
    // adopting the app's styles wrote the settings
    assert.equal(t.store.settings.styles.textColor, '#ffff00');
    for (const k of ['mode', 'targetLang', 'annotateLevel']) assert.ok(!keys().includes(k), k);
    // so does dragging the subtitles
    await t.tabMessage({ type: 'set-drag-mode', enabled: true });
    const text = t.overlayText();
    text.dispatch('pointerdown', { pointerId: 1, clientY: 300 });
    text.dispatch('pointermove', { pointerId: 1, clientY: 250 });
    text.dispatch('pointerup', { pointerId: 1, clientY: 250 });
    await sleep(20);
    assert.equal(t.store.settings.bottomOffset, 20);
    for (const k of ['mode', 'targetLang', 'annotateLevel']) assert.ok(!keys().includes(k), k);
    assert.equal(t.store.settings.prefsUpdatedAt, 0);
    assert.equal((await t.status()).mode, 'netflix');
    t.stop();
  });

  await test('an AI mode without an engine still points to engine setup', async () => {
    const t = boot({ stored: settingsWith({ mode: 'translate' }), ping: () => ({ ok: true, engine: { active: null } }) });
    await toFetch(t);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(20);
    t.port().onMessage.fire({ type: 'error', kind: 'translate', code: 'engine-not-ready' });
    await sleep(150);
    assert.equal(t.hint().textContent, 'MultiSub：還沒設定 AI 引擎，點 Safari 工具列的 MultiSub 圖示設定');
    assert.equal((await t.status()).errorCode, 'engine-not-ready');
    t.stop();
  });

  const toastText = (host) => host.shadowRoot.querySelectorAll('p').map((p) => p.textContent);
  const toastCss = (host) => host.shadowRoot.querySelector('style').textContent;

  await test('toast: once per install, after the ping, on the player container, click-through', async () => {
    let answer;
    const pinged = new Promise((r) => { answer = r; });
    const t = boot({ stored: undefined, ping: () => pinged.then(() => ({ ok: true, engine: null, prefs: { updatedAt: 0 } })) });
    await sleep(250);
    assert.equal(t.toast(), null, 'waits for the startup ping');
    answer();
    await sleep(150);
    const host = t.toast();
    assert.ok(host, 'toast shown');
    assert.equal(host.parentElement, t.container); // same container as the overlay: visible in fullscreen
    assert.equal(t.html.querySelector('#multisub-overlay').parentElement, t.container);
    assert.deepEqual(toastText(host), ['MultiSub 已開啟', '目前使用 Netflix 雙語字幕，第二語言是繁體中文。',
      '點 Safari 工具列的 MultiSub 按鈕可以換模式。']);
    assert.equal(host.shadowRoot.querySelector('.toast').getAttribute('role'), 'status');
    // Click-through: nothing takes pointer events except the close button.
    assert.match(host.style.cssText, /pointer-events:none/);
    assert.match(toastCss(host), /\.toast \{[^}]*pointer-events: none/);
    assert.match(toastCss(host), /\.close \{[^}]*pointer-events: auto/);
    assert.match(toastCss(host), /prefers-reduced-motion: reduce[\s\S]*animation: none; transition: none/);
    assert.equal(host.shadowRoot.querySelector('.close').getAttribute('aria-label'), '關閉');
    assert.ok((host.listeners.click || []).length, 'clicks on the close button stay away from the player');
    assert.equal(t.store.welcomeShown, true);
    // Showing it chose nothing: no mode or timestamp stored, nothing pushed.
    assert.ok(!t.store.settings || !t.store.settings.prefsUpdatedAt);
    assert.ok(!t.runtimeMessages.some((m) => m.type === 'set-prefs'));
    // Netflix swaps the player container (e.g. entering fullscreen): the toast follows.
    const full = new Node('div'); full.classList.add('watch-video');
    t.html.querySelector('body').appendChild(full);
    full.appendChild(t.video);
    await sleep(150);
    assert.equal(host.parentElement, full);
    host.shadowRoot.querySelector('.close').dispatch('click');
    assert.ok(host.shadowRoot.querySelector('.toast').classList.contains('leaving'));
    await sleep(400);
    assert.equal(t.toast(), null);
    t.stop();

    // Next page load: the flag is in storage, no toast.
    const t2 = boot({ stored: undefined, extraStore: { welcomeShown: true }, ping: () => ({ ok: true, engine: null }) });
    await sleep(400);
    assert.equal(t2.toast(), null);
    t2.stop();
  });

  await test('toast: leaves by itself, waits for playback, skipped while off', async () => {
    // scale 0.01: the 8 s timer runs in 80 ms, then the 300 ms fade.
    const t = boot({ stored: undefined, ping: () => ({ ok: true, engine: null }), scale: 0.01 });
    await sleep(150);
    assert.ok(t.toast());
    await sleep(600);
    assert.equal(t.toast(), null);
    t.stop();

    const t2 = boot({ stored: undefined, ping: () => ({ ok: true, engine: null }) });
    t2.video.paused = true;
    await sleep(300);
    assert.equal(t2.toast(), null, 'not on a paused or loading player');
    assert.equal(t2.store.welcomeShown, undefined);
    t2.video.paused = false;
    await sleep(150);
    assert.ok(t2.toast());
    t2.stop();

    const t3 = boot({ stored: settingsWith({ enabled: false }), ping: () => ({ ok: true, engine: null }) });
    await sleep(300);
    assert.equal(t3.toast(), null);
    assert.equal(t3.store.welcomeShown, undefined); // still owed once MultiSub is on
    await t3.setSettings({ enabled: true });
    await sleep(150);
    assert.ok(t3.toast());
    t3.stop();
  });

  await test('toast: says which mode and language are in use, and follows popup changes', async () => {
    const t = boot({ stored: undefined, navigator: { languages: ['ja-JP', 'en-US'] }, ping: () => ({ ok: true, engine: null }) });
    await sleep(200);
    assert.equal(toastText(t.toast())[1], '目前使用 Netflix 雙語字幕，第二語言是日文。');
    await t.setSettings({ mode: 'annotate', prefsUpdatedAt: 9 });
    await sleep(20);
    assert.equal(toastText(t.toast())[1], '目前使用生字標註，難字後面會標上日文的意思。');
    await t.setSettings({ mode: 'translate', targetLang: 'ko', prefsUpdatedAt: 10 });
    await sleep(20);
    assert.equal(toastText(t.toast())[1], '目前使用 AI 翻譯雙語字幕，第二語言是韓文。');
    await t.setSettings({ enabled: false });
    await sleep(20);
    assert.equal(t.toast(), null);
    t.stop();
  });

  await test('DOM fallback: translate line requests; netflix hint', async () => {
    const t = boot({ stored: settingsWith({ mode: 'annotate' }), ping: () => ({ ok: true, engine: cloudEngine }), scale: 0.01 });
    await sleep(150);
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    t.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS });
    await sleep(10);
    // the first failures are retried; only the third one falls back
    for (let i = 0; i < 3; i++) {
      t.fromPage({ type: 'track-error', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', error: 'HTTP 500' });
      await sleep(90);
    }
    const span = new Node('span'); span.textContent = 'He was adamant.';
    t.timedtext.appendChild(span);
    await sleep(150);
    const line = t.port().posted.find((m) => m.type === 'line');
    assert.deepEqual(line, { type: 'line', kind: 'annotate', text: 'He was adamant.', targetLang: 'zh-TW', level: 'B1', sourceLang: 'en' });
    t.port().onMessage.fire({ type: 'line-result', kind: 'annotate', text: 'He was adamant.', result: [{ term: 'adamant', gloss: '堅決' }] });
    await sleep(150);
    assert.equal(t.overlayText().querySelector('.ms-gloss').textContent, '堅決');
    await t.setSettings({ mode: 'netflix', prefsUpdatedAt: 50 });
    await sleep(150);
    assert.equal(t.hint().textContent, '沒有抓到字幕資料，請重新整理頁面（⌘R）');
    assert.ok(!t.html.classList.contains('multisub-native-hidden'));
    t.stop();
  });


  // Shared setup: a translate/annotate tab with tracks reported, primary fetch requested.
  async function toFetch(t, active = 'en') {
    await sleep(150);
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: active, audioBcp47: 'en' });
    t.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS });
    await sleep(20);
  }
  const sourceFetches = (t) => t.pageCommands.filter((c) => c.type === 'fetch-track' && c.purpose === 'source');

  await test('primary fetch failure is retried (bounded); Netflix subtitles stay visible until cues arrive', async () => {
    const t = boot({ stored: settingsWith({ mergedMode: true }), ping: () => ({ ok: true, engine: cloudEngine }), scale: 0.01 });
    await toFetch(t);
    await sleep(150);
    // merged layout, but nothing of ours to draw yet: Netflix's subtitles stay
    assert.ok(!t.html.classList.contains('multisub-native-hidden'));
    assert.equal(sourceFetches(t).length, 1);
    t.fromPage({ type: 'track-error', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', error: 'HTTP 503' });
    await sleep(60); // retry after 2000 ms * 0.01
    assert.equal(sourceFetches(t).length, 2);
    let st = await t.status();
    assert.equal(st.fallback, false);
    assert.equal(st.status, 'fetching');
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(150);
    st = await t.status();
    assert.equal(st.status, 'translating');
    assert.ok(t.html.classList.contains('multisub-native-hidden'));
    assert.ok(t.port().posted.some((m) => m.type === 'job'));
    t.stop();

    // retries used up -> DOM fallback; a fresh track list later gets the full track back
    const t2 = boot({ stored: settingsWith({ mergedMode: true }), ping: () => ({ ok: true, engine: cloudEngine }), scale: 0.01 });
    await toFetch(t2);
    for (let i = 0; i < 3; i++) {
      t2.fromPage({ type: 'track-error', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', error: 'HTTP 403' });
      await sleep(90);
    }
    assert.equal(sourceFetches(t2).length, 3);
    assert.equal((await t2.status()).fallback, true);
    t2.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS }); // inject re-posts after Netflix's new manifest
    await sleep(30);
    assert.equal(sourceFetches(t2).length, 4);
    t2.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    await sleep(30);
    const st2 = await t2.status();
    assert.equal(st2.fallback, false);
    assert.equal(st2.totalCues, 50);
    t2.stop();
  });

  await test('tracks-timeout window: native subtitles are not hidden while there is nothing to draw', async () => {
    const t = boot({ stored: settingsWith({ mode: 'annotate' }), ping: () => ({ ok: true, engine: cloudEngine }) });
    await sleep(350);
    assert.equal((await t.status()).status, 'waiting-tracks');
    assert.ok(!t.html.classList.contains('multisub-native-hidden'));
    t.stop();
  });

  await test('episode change resets a manual source-track pick', async () => {
    const t = boot({ stored: settingsWith({}), ping: () => ({ ok: true, engine: cloudEngine }) });
    await toFetch(t);
    await t.tabMessage({ type: 'set-track', trackId: 'ja:SUBTITLES:3' });
    let st = await t.status();
    assert.equal(st.sourceMode, 'manual');
    assert.equal(st.activeTrackId, 'ja:SUBTITLES:3');
    t.navigate('/watch/82');
    await sleep(150);
    st = await t.status();
    assert.equal(st.movieId, '82');
    assert.equal(st.sourceMode, 'auto');
    // the next episode follows Netflix's player again (waits for its report)
    t.fromPage({ type: 'tracks', movieId: '82', tracks: TRACKS });
    t.fromPage({ type: 'active-track', movieId: '82', bcp47: 'en', audioBcp47: 'en' });
    await sleep(30);
    const last = sourceFetches(t).pop();
    assert.equal(last.movieId, '82');
    assert.equal(last.trackId, 'en:SUBTITLES:0');
    t.stop();
  });

  async function runningJob(t, mode = 'translate', cues = EN_CUES) {
    await toFetch(t);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(20);
    return t.port();
  }

  await test('partial done: brief notice instead of the error hint, missing lines retried quietly', async () => {
    const t = boot({ stored: settingsWith({}), ping: () => ({ ok: true, engine: cloudEngine }), scale: 0.01 });
    const port = await runningJob(t);
    port.onMessage.fire({ type: 'progress', kind: 'translate', start: 0, items: EN_CUES.slice(0, 40).map((c) => 'T ' + c.text) });
    port.onMessage.fire({ type: 'done', kind: 'translate', partial: true, missing: 10, code: 'provider-error' });
    await sleep(150);
    let st = await t.status();
    assert.equal(st.status, 'done');
    assert.equal(st.errorCode, null);
    assert.equal(st.errorHint, '');
    assert.equal(st.partialMissing, 10);
    assert.equal(t.hint().textContent, 'MultiSub：有部分字幕翻譯失敗，稍後會自動補上');
    assert.equal(t.overlayText().textContent, 'T line 7');
    await sleep(300); // AUTO_RETRY_MS * 0.01
    assert.ok(port.disconnected);
    assert.notEqual(t.port(), port);
    assert.equal(t.port().posted[0].type, 'job');
    st = await t.status();
    assert.equal(st.status, 'translating');
    // a complete 'done' clears it
    t.port().onMessage.fire({ type: 'done', kind: 'translate', fromCache: true });
    st = await t.status();
    assert.equal(st.partialMissing, 0);
    t.stop();
  });

  await test('superseded job: stops waiting and asks again later', async () => {
    const t = boot({ stored: settingsWith({}), ping: () => ({ ok: true, engine: cloudEngine }), scale: 0.01 });
    const port = await runningJob(t);
    port.onMessage.fire({ type: 'superseded', kind: 'translate' });
    await sleep(350);
    assert.ok(port.disconnected);
    assert.equal(t.port().posted[0].type, 'job');
    t.stop();
  });

  await test('DOM fallback on the local engine: one line in flight; dropped lines are asked again', async () => {
    const localEngine = { configured: 'auto', active: 'local', provider: 'anthropic', hasKey: false, localModelDownloaded: true };
    const t = boot({ stored: settingsWith({ mode: 'translate' }), ping: () => ({ ok: true, engine: localEngine }) });
    await toFetch(t);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: [] }); // -> fallback
    const span = new Node('span'); span.textContent = 'Line A';
    t.timedtext.appendChild(span);
    await sleep(150);
    span.textContent = 'Line B';
    await sleep(250);
    const lines = () => t.port().posted.filter((m) => m.type === 'line').map((m) => m.text);
    assert.deepEqual(lines(), ['Line A']); // B waits for A
    t.port().onMessage.fire({ type: 'line-result', kind: 'translate', text: 'Line A', result: '甲' });
    await sleep(150);
    assert.deepEqual(lines(), ['Line A', 'Line B']);
    t.port().onMessage.fire({ type: 'line-result', kind: 'translate', text: 'Line B', dropped: true });
    await sleep(150);
    assert.deepEqual(lines(), ['Line A', 'Line B', 'Line B']); // still on screen: asked again
    assert.equal((await t.status()).errorCode, null);
    t.port().onMessage.fire({ type: 'line-result', kind: 'translate', text: 'Line B', result: '乙' });
    await sleep(150);
    assert.equal(t.overlayText().textContent, '乙');
    t.stop();
  });

  await test('annotations: curly apostrophes match like Swift; terms not in the line use no repeat budget', async () => {
    const cues = [
      { start: 28, end: 31, text: 'I can’t stand him.' },
      ...Array.from({ length: 4 }, (_, i) => ({ start: 40 + i * 4, end: 43 + i * 4, text: i < 3 ? 'nothing here ' + i : 'a stand-up guy' }))
    ];
    const t = boot({ stored: settingsWith({ mode: 'annotate' }), ping: () => ({ ok: true, engine: cloudEngine }) });
    const port = await runningJob(t, 'annotate', cues);
    port.onMessage.fire({ type: 'progress', kind: 'annotate', start: 0, items: [
      [{ term: "can't stand", gloss: '受不了' }, { term: 'nowhere', gloss: '無處' }],
      [{ term: 'stand', gloss: '站' }], [{ term: 'stand', gloss: '站' }], [{ term: 'stand', gloss: '站' }],
      [{ term: 'stand', gloss: '站' }]
    ] });
    await sleep(150);
    assert.equal(t.overlayText().querySelector('.ms-term').textContent, 'can’t stand');
    assert.equal(t.overlayText().querySelector('.ms-gloss').textContent, '受不了');
    assert.equal(t.overlayText().querySelectorAll('.ms-term').length, 1);
    t.video.currentTime = 53; // cue 4: "a stand-up guy", the term's first real occurrence
    await sleep(150);
    assert.equal(t.overlayText().querySelector('.ms-gloss').textContent, '站');
    t.stop();
  });

  await test('cues from an inject.js older than `cleaned` lose their direction marks; flagged ones are taken as they are', async () => {
    const t = boot({ stored: settingsWith({ mode: 'netflix' }), ping: () => ({ ok: true, engine: null }) });
    await toFetch(t);
    const marked = (cues, f) => cues.map((c, i) => Object.assign({}, c, { text: f(c.text, i) }));
    // What a shipped inject.js made of Netflix's TTML: "&amp;lrm;" as the
    // text "&lrm;", "&#8206;" as U+200E, a double-encoded one, a mark alone.
    const zh = marked(ZH_CUES, (text, i) => [
      '&lrm;' + text, '‎' + text + ' ', '&amp;lrm;' + text, '&#x200F;‫' + text + '‬'][i % 4]);
    zh.push({ start: 201, end: 202, text: '&lrm;' });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: zh });
    await sleep(150);
    for (const [time, want] of [[13, '第 3 句'], [17, '第 4 句'], [21, '第 5 句'], [25, '第 6 句'], [30, '第 7 句']]) {
      t.video.currentTime = time;
      await sleep(120);
      assert.equal(JSON.stringify(t.overlayText().textContent), JSON.stringify(want), 'at ' + time + ' s');
    }
    t.video.currentTime = 201.5;
    await sleep(120);
    assert.equal(t.overlayText().style.display, 'none', 'a cue that was only a mark is gone');
    // An inject.js that cleans its cues says so, and they are used as sent.
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cleaned: true,
      cues: [{ start: 0, end: 200, text: 'A&B  as sent ' }] });
    t.video.currentTime = 30;
    await sleep(120);
    assert.equal(t.overlayText().textContent, 'A&B  as sent ');
    t.stop();
  });

  await test('the lower line is drawn smaller only while it is the second of two lines', async () => {
    const twoLines = (t) => t.html.querySelector('#multisub-overlay').classList.contains('multisub-two-lines');
    const t = boot({ stored: settingsWith({ mode: 'translate' }), ping: () => ({ ok: true, engine: cloudEngine }) });
    const port = await runningJob(t);
    await sleep(150);
    // the original alone while its translation is pending
    assert.equal(t.overlayOriginal().textContent, 'line 7');
    assert.equal(t.overlayText().style.display, 'none');
    assert.ok(!twoLines(t));
    port.onMessage.fire({ type: 'progress', kind: 'translate', start: 7, items: ['翻譯七'] });
    await sleep(150);
    assert.ok(twoLines(t), 'original + translation');
    // Not merged, Netflix draws the original: still the second of two lines.
    t.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    await t.setSettings({ mergedMode: false });
    await sleep(150);
    assert.equal(t.overlayOriginal().style.display, 'none');
    assert.equal(t.overlayText().textContent, '翻譯七');
    assert.ok(twoLines(t), "under Netflix's own line");
    // annotate: the one line is the original itself
    await t.setSettings({ mode: 'annotate', mergedMode: true, prefsUpdatedAt: 20 });
    await sleep(150);
    assert.equal(t.overlayText().textContent, 'line 7');
    assert.ok(!twoLines(t), 'annotate');
    // back to two lines in netflix mode
    await t.setSettings({ mode: 'netflix', prefsUpdatedAt: 30 });
    await sleep(150);
    assert.equal(t.overlayText().textContent, '第 7 句');
    assert.ok(twoLines(t), 'netflix');
    t.stop();

    // passthrough: the original is already in the target language
    const t2 = boot({ stored: settingsWith({ mode: 'translate', targetLang: 'en' }), ping: () => ({ ok: true, engine: cloudEngine }) });
    await sleep(150);
    t2.fromPage({ type: 'active-track', movieId: '81', bcp47: 'en', audioBcp47: 'en' });
    t2.fromPage({ type: 'tracks', movieId: '81', tracks: TRACKS.slice(0, 1) });
    await sleep(20);
    t2.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    await sleep(150);
    assert.equal((await t2.status()).status, 'passthrough');
    assert.equal(t2.overlayText().textContent, 'line 7');
    assert.ok(!twoLines(t2), 'passthrough');
    t2.stop();
  });

  await test("netflix mode: the second line keeps its size while its cue outlasts the original's", async () => {
    const twoLines = (t) => t.html.querySelector('#multisub-overlay').classList.contains('multisub-two-lines');
    // Netflix times each language on its own: here every Chinese cue ends
    // 0.9 s after its English one.
    const zh = Array.from({ length: 50 }, (_, i) => ({ start: i * 4, end: i * 4 + 3.9, text: '第 ' + i + ' 句' }));
    const t = boot({ stored: settingsWith({ mode: 'netflix' }), ping: () => ({ ok: true, engine: null }) });
    await toFetch(t);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: zh });
    const at = async (time) => { t.video.currentTime = time; await sleep(150); };
    await at(30.5);
    assert.equal(t.overlayOriginal().textContent, 'line 7');
    assert.equal(t.overlayText().textContent, '第 7 句');
    assert.ok(twoLines(t), 'both cues on screen');
    await at(31.5);
    assert.equal(t.overlayOriginal().style.display, 'none', 'the English cue has ended');
    assert.equal(t.overlayText().textContent, '第 7 句');
    assert.ok(twoLines(t), 'the same Chinese cue, the same size');
    // Not merged: Netflix draws the English line, on the same timeline.
    await t.setSettings({ mergedMode: false });
    await at(30.5);
    assert.equal(t.overlayText().textContent, '第 7 句');
    assert.ok(twoLines(t), "under Netflix's own line");
    await at(31.5);
    assert.ok(twoLines(t), "after Netflix's own line has gone");
    t.stop();
  });

  // --- Several instances on one page (the extension reloaded under an open
  // tab) and an instance whose extension context is gone.
  const overlaysOn = (page) => page.html.querySelectorAll('#multisub-overlay');
  const instanceStyles = (page) => page.html.querySelectorAll('style').filter((n) => n.getAttribute('data-ms-instance'));
  const instanceOf = (node) => node.getAttribute('data-ms-instance');
  // Netflix mode with both tracks loaded, drawing at 30 s.
  async function netflixReady(t) {
    await toFetch(t);
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'zh:SUBTITLES:2', purpose: 'reference', cues: ZH_CUES });
    await sleep(150);
  }
  // Nothing of `t` is left running or on the page.
  function assertTornDown(t, ownOverlay) {
    assert.equal(ownOverlay.parentElement, null, 'overlay removed');
    assert.equal(t.onMessage.l.length, 0, 'runtime.onMessage listener removed');
    assert.equal(t.storageChanged.l.length, 0, 'storage.onChanged listener removed');
    assert.ok(t.ports.every((p) => p.disconnected), 'port disconnected');
    assert.ok(!instanceStyles(t.page).some((n) => instanceOf(n) === instanceOf(ownOverlay)), 'style rule removed');
  }

  await test('a newer instance takes over the page: the older one stops, and only the newer one draws', async () => {
    const page = makePage('/watch/81');
    const ping = () => ({ ok: true, engine: cloudEngine });
    const a = boot({ page, stored: settingsWith({ mode: 'translate' }), ping, clock: 100 });
    const aPort = await runningJob(a);
    aPort.onMessage.fire({ type: 'progress', kind: 'translate', start: 7, items: ['翻譯七'] });
    await sleep(150);
    const aOverlay = overlaysOn(page)[0];
    const aId = instanceOf(aOverlay);
    assert.ok(/^[0-9a-z]+$/.test(aId), aId);
    assert.equal(a.overlayText().textContent, '翻譯七');
    // An overlay drawn by a version already shipped, which knows nothing of this.
    const shipped = new Node('div'); shipped.id = 'multisub-overlay';
    page.container.appendChild(shipped);

    // The extension is reloaded: a new instance (another world, the same
    // storage, now in netflix mode) starts on the same page.
    a.store.settings = settingsWith({ mode: 'netflix', prefsUpdatedAt: 20 });
    const b = boot({ page, store: a.store, ping, clock: 200 });
    await sleep(30);
    assertTornDown(a, aOverlay);
    assert.equal(page.winListeners.length, 1, "only the new instance listens to the page");
    // The new instance asks inject.js again and draws from what it gets.
    await netflixReady(b);
    assert.equal(page.pageCommands.filter((c) => c.type === 'get-tracks').length, 2);
    const overlays = overlaysOn(page);
    assert.equal(overlays.length, 1, 'one overlay on the page');
    const bId = instanceOf(overlays[0]);
    assert.notEqual(bId, aId);
    assert.equal(shipped.parentElement, null, "the shipped version's overlay was taken off when ours went on");
    assert.equal(b.overlayOriginal().textContent, 'line 7');
    assert.equal(b.overlayText().textContent, '第 7 句');
    assert.ok(page.html.classList.contains('multisub-native-hidden'));
    const styles = instanceStyles(page);
    assert.equal(styles.length, 1);
    assert.equal(instanceOf(styles[0]), bId);
    assert.equal(styles[0].textContent,
      '[id^="multisub-"]:not([data-ms-instance="' + bId + '"]):not([data-ms-instance="' + bId + '"] *) { display: none !important; }');
    // The old instance stays quiet: no tick puts its overlay back, and page
    // messages no longer reach it.
    page.container.appendChild(shipped);
    await sleep(250);
    assert.equal(aOverlay.parentElement, null);
    assert.equal(overlaysOn(page).length, 2, 'the shipped overlay is back (hidden by the style rule), ours stays');
    assert.equal((await b.status()).mode, 'netflix');
    a.stop(); b.stop();
  });

  await test('instances that start close together: exactly one survives, in either order', async () => {
    const ping = () => ({ ok: true, engine: null });
    // Same start time: the id decides, the same way on both sides.
    const page = makePage('/watch/81');
    const a = boot({ page, stored: settingsWith({ mode: 'netflix' }), ping, clock: 100 });
    const b = boot({ page, store: a.store, ping, clock: 100 });
    const ids = instanceStyles(page).map(instanceOf);
    assert.equal(ids.length, 2);
    await sleep(250);
    const alive = [a, b].filter((t) => t.onMessage.l.length);
    assert.equal(alive.length, 1);
    assert.equal(page.winListeners.length, 1);
    assert.equal(overlaysOn(page).length, 1);
    assert.equal(instanceOf(overlaysOn(page)[0]), ids.sort()[1]);
    a.stop(); b.stop();

    // The newer one starts first: the older one's hello gets an answer, and
    // it steps aside.
    const page2 = makePage('/watch/81');
    const newer = boot({ page: page2, stored: settingsWith({ mode: 'netflix' }), ping, clock: 200 });
    await sleep(150);
    const newerOverlay = overlaysOn(page2)[0];
    const older = boot({ page: page2, store: newer.store, ping, clock: 150 });
    await sleep(250);
    assert.equal(older.onMessage.l.length, 0, 'the older instance tore itself down');
    assert.equal(newer.onMessage.l.length, 1);
    assert.deepEqual(overlaysOn(page2), [newerOverlay]);
    newer.stop(); older.stop();
  });

  await test("a newer instance's hello: Netflix's subtitles are left to it; a forged one from the future is ignored", async () => {
    const hello = (page, fields) => page.window.postMessage(Object.assign({ __multisub_instance: true, type: 'hello' }, fields));
    const t = boot({ stored: settingsWith({ mode: 'netflix' }), ping: () => ({ ok: true, engine: null }), clock: 100 });
    await netflixReady(t);
    const own = overlaysOn(t.page)[0];
    assert.ok(t.html.classList.contains('multisub-native-hidden'));
    hello(t.page, { id: 'zzzz', startedAt: 1e12, managesNative: true });
    hello(t.page, { id: 'zzzz', startedAt: 'soon', managesNative: true });
    await sleep(150);
    assert.equal(own.parentElement, t.container, 'still drawing');
    hello(t.page, { id: 'zzzz', startedAt: 150, managesNative: true });
    await sleep(150);
    assertTornDown(t, own);
    assert.ok(t.html.classList.contains('multisub-native-hidden'), 'the newer instance decides about the class now');
    t.stop();

    // A newer instance that doesn't say it manages the class: give it back.
    const t2 = boot({ stored: settingsWith({ mode: 'netflix' }), ping: () => ({ ok: true, engine: null }), clock: 100 });
    await netflixReady(t2);
    hello(t2.page, { id: 'zzzz', startedAt: 150 });
    await sleep(150);
    assert.ok(!t2.html.classList.contains('multisub-native-hidden'));
    t2.stop();
  });

  await test('extension context gone: the instance tears itself down and gives Netflix its subtitles back', async () => {
    const ping = () => ({ ok: true, engine: cloudEngine });
    // runtime.id cleared (Chrome-style engines)
    const t = boot({ stored: settingsWith({ mode: 'translate' }), ping });
    const port = await runningJob(t);
    port.onMessage.fire({ type: 'progress', kind: 'translate', start: 7, items: ['翻譯七'] });
    await sleep(150);
    const own = overlaysOn(t.page)[0];
    assert.ok(t.html.classList.contains('multisub-native-hidden'));
    t.browser.runtime.id = undefined;
    await sleep(150);
    assertTornDown(t, own);
    assert.ok(port.disconnected);
    assert.ok(!t.html.classList.contains('multisub-native-hidden'));
    assert.equal(t.page.winListeners.length, 0);
    // Nothing comes back on later ticks or page messages.
    t.fromPage({ type: 'cues', movieId: '81', trackId: 'en:SUBTITLES:0', purpose: 'source', cues: EN_CUES });
    await sleep(250);
    assert.equal(overlaysOn(t.page).length, 0);
    assert.equal(t.ports.length, 1);
    t.stop();

    // runtime calls throwing
    const t2 = boot({ stored: settingsWith({ mode: 'netflix' }), ping });
    await netflixReady(t2);
    const own2 = overlaysOn(t2.page)[0];
    t2.browser.runtime.getURL = () => { throw new Error('Extension context invalidated.'); };
    await sleep(150);
    assertTornDown(t2, own2);
    assert.ok(!t2.html.classList.contains('multisub-native-hidden'));
    t2.stop();

    // WebKit: runtime.id stays, but the context's stylesheet leaves the page.
    const withStylesheet = async () => {
      const page = makePage('/watch/81');
      page.rootStyle['--multisub-stylesheet'] = ' 1';
      page.overlaySheet = true;
      const t = boot({ page, stored: settingsWith({ mode: 'netflix' }), ping });
      await netflixReady(t);
      await sleep(1000); // the stylesheet is looked at once a second
      const own = overlaysOn(t.page)[0];
      assert.equal(own.parentElement, t.container);
      assert.ok(t.html.classList.contains('multisub-native-hidden'));
      return { t, own };
    };
    const { t: t3, own: own3 } = await withStylesheet();
    delete t3.page.rootStyle['--multisub-stylesheet'];
    t3.page.overlaySheet = false;
    await sleep(1150);
    assertTornDown(t3, own3);
    assert.ok(!t3.html.classList.contains('multisub-native-hidden'));
    t3.stop();

    // A runtime that says the context is gone while its stylesheet stays
    // (marker and all): no other instance to leave the class to.
    const { t: t4, own: own4 } = await withStylesheet();
    t4.browser.runtime.id = undefined;
    await sleep(150);
    assertTornDown(t4, own4);
    assert.ok(!t4.html.classList.contains('multisub-native-hidden'));
    t4.stop();
  });

  await test('reloaded onto an older build (no marker, no hello): the class is left to it', async () => {
    const ping = () => ({ ok: true, engine: null });
    const page = makePage('/watch/81');
    page.rootStyle['--multisub-stylesheet'] = ' 1';
    page.overlaySheet = true;
    const t = boot({ page, stored: settingsWith({ mode: 'netflix' }), ping });
    await netflixReady(t);
    await sleep(1000);
    const own = overlaysOn(page)[0];
    // Safari swaps this build's overlay.css for the older one's, which has
    // no marker, and the older content.js draws its own overlay. It set the
    // class when its cues came and, like the versions already shipped, sets
    // it again only when its own idea of it changes.
    delete page.rootStyle['--multisub-stylesheet'];
    const older = new Node('div'); older.id = 'multisub-overlay';
    page.container.appendChild(older);
    await sleep(1150);
    assertTornDown(t, own);
    assert.deepEqual(overlaysOn(page), [older]);
    assert.ok(t.html.classList.contains('multisub-native-hidden'), "Netflix's line stays hidden under the older build's");
    t.stop();

    // Same, with this instance's overlay never attached (no video yet): the
    // older build's overlay tells which stylesheet is on the page.
    const page2 = makePage('/watch/81');
    page2.rootStyle['--multisub-stylesheet'] = ' 1';
    page2.overlaySheet = true;
    page2.video.remove();
    const t2 = boot({ page: page2, stored: settingsWith({ mode: 'netflix' }), ping });
    await sleep(1150);
    assert.equal(overlaysOn(page2).length, 0);
    delete page2.rootStyle['--multisub-stylesheet'];
    const older2 = new Node('div'); older2.id = 'multisub-overlay';
    page2.container.appendChild(older2);
    page2.html.classList.add('multisub-native-hidden');
    await sleep(1150);
    assert.equal(t2.onMessage.l.length, 0, 'torn down');
    assert.ok(page2.html.classList.contains('multisub-native-hidden'));
    t2.stop();
  });

  await test('a torn-down instance opens no port when a late engine-changed ping answers', async () => {
    let slow = false;
    const reply = { ok: true, engine: cloudEngine };
    const ping = () => (slow ? sleep(400).then(() => reply) : reply);
    const t = boot({ stored: settingsWith({ mode: 'translate' }), ping, clock: 100 });
    const port = await runningJob(t);
    port.onMessage.fire({ type: 'error', kind: 'translate', code: 'engine-not-ready' });
    await sleep(50);
    assert.equal((await t.status()).errorCode, 'engine-not-ready');
    const own = overlaysOn(t.page)[0];
    // The popup saved an engine; before the ping it sends answers, a newer
    // instance takes over.
    slow = true;
    await t.tabMessage({ type: 'engine-changed' });
    t.page.window.postMessage({ __multisub_instance: true, type: 'hello', id: 'zzzz', startedAt: 150, managesNative: true });
    await sleep(100);
    assertTornDown(t, own);
    const portsAtTeardown = t.ports.length;
    await sleep(500); // the ping has answered
    assert.equal(t.ports.length, portsAtTeardown, 'no port opened after teardown');
    assert.ok(t.ports.every((p) => p.disconnected));
    assert.ok(!t.ports.some((p) => p.posted.length && p !== port), 'no job sent');
    t.stop();
  });

  console.log('\n' + passed + ' tests passed' + (process.exitCode ? ', some FAILED' : ''));
  process.exit(process.exitCode || 0);
})();

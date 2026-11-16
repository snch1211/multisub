'use strict';
// Drives the real popup (extension/popup.html + popup.js + shared.js) in
// headless Chrome with a scripted browser API (popup/mock.js) and one
// scenario per page load (popup/driver.js).
const assert = require('assert/strict');
const EXT = process.env.EXT || require('path').resolve(__dirname, '../../extension');
const runner = require('./popup/runner');

// One scenario per page load, in WebKit or headless Chrome (popup/runner.js).
function run(cfg) {
  return runner.run(cfg, { ext: EXT });
}

const providers = (extra = {}) => [
  Object.assign({ id: 'anthropic', name: 'Anthropic Claude', defaultModel: 'claude-haiku-5-5', keyPlaceholder: 'sk-ant-…', keyURL: 'https://console.anthropic.com/settings/keys', needsBaseURL: false, keyRequired: true, hasKey: false,
    recommended: [{ id: 'claude-haiku-5-5', label: '最快（推薦）' }] }, extra.anthropic),
  Object.assign({ id: 'openai', name: 'OpenAI', defaultModel: 'gpt-6-luna', keyPlaceholder: 'sk-…', keyURL: 'https://platform.openai.com/api-keys', needsBaseURL: false, keyRequired: true, hasKey: false,
    recommended: [{ id: 'gpt-6-luna', label: '最快（推薦）' }, { id: 'gpt-6.1-terra', label: '平衡' }] }, extra.openai),
  Object.assign({ id: 'custom', name: '自訂（OpenAI 相容）', defaultModel: '', keyPlaceholder: '選填', needsBaseURL: true, keyRequired: false, hasKey: false, recommended: [] }, extra.custom)
];
const engineNone = { configured: 'auto', active: null, provider: 'anthropic', providerName: 'Anthropic Claude', model: 'claude-haiku-5-5', hasKey: false,
  localModelId: 'mlx-community/gemma-4-e4b-it-4bit', localModelDownloaded: false, localModelLoaded: false };
const engineCloud = Object.assign({}, engineNone, { configured: 'cloud', active: 'cloud', hasKey: true });
const translateSettings = { settings: { enabled: true, mode: 'translate', targetLang: 'zh-TW', annotateLevel: 'B1', fontScale: 1, bottomOffset: 10, mergedMode: true, prefsUpdatedAt: 5 } };
const base = (scenario, extra) => Object.assign({ scenario, engine: engineNone, providers: providers(), store: translateSettings,
  tabUrl: 'https://www.netflix.com/watch/81', status: { onWatchPage: true, status: 'error', errorCode: 'engine-not-ready', tracks: [], totalCues: 10, translatedCount: 0 } }, extra || {});

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('ok   ' + name); }
  catch (e) { console.log('FAIL ' + name + '\n     ' + (e.stack || e.message).split('\n').slice(0, 4).join('\n     ')); process.exitCode = 1; }
}

test('AI engine set up: its name, and 到 App 變更 opens the app instead of a form', () => {
  const r = run(base('engine-card', { engine: engineCloud }));
  assert.equal(r.card.summaryShown, true);
  assert.equal(r.card.summary, 'Anthropic Claude · claude-haiku-5-5');
  assert.equal(r.card.change, '到 App 變更');
  assert.equal(r.card.setupShown, false);
  assert.deepEqual(r.card.formFields, []); // no key, provider or model fields in the popup
  assert.deepEqual(r.sent, [{ type: 'open-app', destination: 'general' }]);
  assert.equal(r.notice, '已打開 MultiSub App，設定好後回來就能用');
  const local = run(base('engine-card', { engine: Object.assign({}, engineNone, { configured: 'local', active: 'local', localModelDownloaded: true }) }));
  assert.equal(local.card.summary, '本機模型 · gemma-4-e4b-it-4bit');
});

test('no AI engine yet: says why and offers the app, which may fail to open', () => {
  const r = run(base('engine-card'));
  assert.equal(r.card.summaryShown, false);
  assert.equal(r.card.setupShown, true);
  assert.equal(r.card.setupText, 'AI 翻譯和生字標註需要 AI 引擎，在 MultiSub App 設定');
  assert.equal(r.card.openLabel, '打開 MultiSub App 設定');
  assert.deepEqual(r.sent, [{ type: 'open-app', destination: 'general' }]);
  const notDownloaded = run(base('engine-card', { engine: Object.assign({}, engineNone, { configured: 'local' }) }));
  assert.equal(notDownloaded.card.setupText, '本機模型還沒下載，到 MultiSub App 下載後就能用');
  const fails = run(base('engine-card', { replies: { 'open-app': { ok: false, error: 'open-failed' } } }));
  assert.equal(fails.notice, '打不開 MultiSub App，請確認已安裝');
  assert.equal(fails.noticeCls, 'engine-notice err');
});

test('Netflix tab without access (URL hidden): 允許存取 banner, no "open Netflix" status or button', () => {
  const r = run(base('perm', { permission: false, tabUrl: undefined, status: null }));
  assert.equal(r.banner, 'MultiSub 還沒有 Netflix 的存取權限');
  assert.equal(r.action, '允許存取');
  assert.equal(r.status, '允許存取 Netflix 後就會開始');
  assert.equal(r.openNetflixShown, false);
});

// An English episode playing in the tab, so 整理本集單字 is enabled.
const watchingEnglish = { onWatchPage: true, movieId: '81', status: 'ready', secondState: 'ready', totalCues: 10, translatedCount: 0,
  tracks: [{ id: 'en1', language: 'en', label: 'English', trackType: 'PRIMARY' }], activeTrackId: 'en1' };
// 整理本集單字 needs an engine, so these run with one set up.
const vocabBase = (scenario, extra) => base(scenario, Object.assign({ status: watchingEnglish, engine: engineCloud }, extra || {}));
const distinct = (list) => list.filter((x, i) => i === 0 || x !== list[i - 1]);

test('整理本集單字: handed off, then the app\'s progress, polled until done; 打開生詞本 opens the app', () => {
  const r = run(vocabBase('vocab-handoff', { vocabAfter: [
    { ok: true, state: 'queued', accepted: false, done: 0, total: 0 },
    { ok: true, state: 'running', accepted: true, done: 0, total: 12 },
    { ok: true, state: 'running', accepted: true, done: 3, total: 12 },
    { ok: true, state: 'running', accepted: true, done: 7, total: 12 },
    { ok: true, state: 'done', accepted: true, done: 12, total: 12, wordCount: 48 }
  ] }));
  assert.deepEqual(r.before, { shown: false, calls: 1 }); // asked once for this episode; nothing to show
  assert.equal(r.organizeSent, 1);
  const shown = r.seen.filter((s) => s.shown);
  assert.deepEqual(distinct(shown.map((s) => s.text)),
    ['正在交給 MultiSub App…', '已交給 MultiSub App，稍後開始整理', '準備中…', '整理中（3/12）', '整理中（7/12）', '整理好了：48 個單字']);
  const running = shown.find((s) => s.text === '整理中（3/12）');
  assert.equal(running.spinner, true);
  assert.equal(running.disabled, true); // pressing it again would change nothing
  assert.equal(running.open, false);
  assert.equal(running.sub, '約需幾分鐘，可以繼續看片');
  const done = shown[shown.length - 1];
  assert.deepEqual(done, { shown: true, text: '整理好了：48 個單字', sub: '',
    cls: 'vocab-status-text ok', spinner: false, open: true, disabled: false });
  assert.equal(r.callsAfter, r.callsAtDone, 'no more polling once done');
  assert.ok(r.movieIds.every((id) => id === '81'));
  assert.deepEqual(r.openApp, [{ type: 'open-app', destination: 'vocab' }]);
  assert.equal(r.sub, '沒看到的話，請切到 MultiSub App 的「生詞本」');
  // 打開生詞本 when the app can't be opened
  const r2 = run(vocabBase('vocab-handoff', { replies: { 'open-app': { ok: false, error: 'open-failed' } },
    vocabAfter: [{ ok: true, state: 'done', accepted: true, done: 3, total: 3, wordCount: 5 }] }));
  assert.equal(r2.sub, '打不開 MultiSub App，請確認已安裝');
  assert.match(r2.subCls, /err/);
});

test('opening on an episode with a recent status shows it; polls only while queued or running', () => {
  const done = run(vocabBase('vocab-on-open', { vocabInitial: { ok: true, state: 'done', done: 4, total: 4, wordCount: 21 } }));
  assert.equal(done.first.text, '整理好了：21 個單字');
  assert.equal(done.first.open, true);
  assert.equal(done.calls, 1);
  const running = run(vocabBase('vocab-on-open', { vocabInitial: { ok: true, state: 'running', accepted: true, done: 2, total: 9 } }));
  assert.equal(running.first.text, '整理中（2/9）');
  assert.equal(running.first.spinner, true);
  assert.equal(running.first.disabled, true);
  assert.ok(running.calls >= 3, 'polled about every 2 s, got ' + running.calls);
  const none = run(vocabBase('vocab-on-open'));
  assert.equal(none.first.shown, false);
  assert.equal(none.first.disabled, false);
  assert.equal(none.calls, 1);
});

test('a failed run shows the reason and what to do, from the code (or the app\'s message for an unknown one)', () => {
  const text = (status) => run(vocabBase('vocab-on-open', { vocabInitial: Object.assign({ ok: true, state: 'failed', accepted: true }, status) })).first;
  const engine = text({ code: 'engine-not-ready', message: '尚未設定 AI 引擎' });
  assert.equal(engine.text, '還沒設定 AI 引擎。切到「AI 翻譯」就能設定，設好後再整理一次');
  assert.equal(engine.cls, 'vocab-status-text err');
  assert.equal(engine.disabled, false); // pressing it again is the retry
  assert.equal(engine.open, false);
  // The app writes this when it quits mid-run: no spinner, and the button is free again.
  const interrupted = text({ code: 'vocab-interrupted' });
  assert.equal(interrupted.text, '整理到一半停了，可能是 App 被關掉，再整理一次就好');
  assert.equal(interrupted.spinner, false);
  assert.equal(interrupted.disabled, false);
  // The appex writes this when it staged the transcript but couldn't open the app.
  const openFailed = text({ accepted: false, code: 'open-failed' });
  assert.equal(openFailed.text, '打不開 MultiSub App，請確認已安裝');
  assert.equal(openFailed.spinner, false);
  assert.equal(openFailed.disabled, false);
  assert.equal(text({ code: 'auth-failed' }).text, '整理失敗：API Key 無效或已過期，請重新貼上');
  assert.equal(text({ code: 'vocab-failed', message: '整理失敗：伺服器沒有回應。' }).text, '整理失敗：伺服器沒有回應。');
});

test('整理本集單字 that never reaches the app: the error under the button, no status', () => {
  const r = run(vocabBase('vocab-click-error', { organizeReply: { ok: false, error: 'open-failed' } }));
  assert.equal(r.hint, '打不開 MultiSub App，請確認已安裝');
  assert.match(r.cls, /err/);
  assert.equal(r.shown, false);
  assert.equal(r.disabled, false);
  const r2 = run(vocabBase('vocab-click-error', { organizeThrows: true }));
  assert.equal(r2.hint, '連不到 Netflix 分頁');
});

test('slow first ping: neutral loading state, then the real view', () => {
  const r = run(base('slow-ping', { pingDelay: 2000 }));
  assert.equal(r.snaps[0].loading, true);
  assert.equal(r.snaps[1].mainShown, true);
  assert.equal(r.snaps[1].engineCard, true);
});

test('no settings yet: everyday view in Netflix mode with the system language, nothing stamped or pushed', () => {
  const r = run(base('defaults', { store: {}, languages: ['ja-JP', 'en-US'], status: { onWatchPage: true, status: 'ready', secondState: 'ready', tracks: [] } }));
  assert.deepEqual(r.checked, ['netflix']);
  assert.equal(r.targetLang, 'ja');
  assert.equal(r.modeDesc, '疊上 Netflix 官方的第二語言字幕，免設定');
  assert.equal(r.mainShown, true);
  assert.equal(r.displaySettings, true);
  assert.equal(r.vocabShown, true);
  assert.equal(r.engineCard, false); // Netflix mode needs no engine
  assert.equal(r.chooser, false);
  assert.deepEqual(r.sentPrefs, []);
  assert.ok(!r.stored || !r.stored.prefsUpdatedAt);
  // zh-Hant system language, and one the extension doesn't offer
  assert.equal(run(base('defaults', { store: {}, languages: ['zh-Hant-TW'] })).targetLang, 'zh-TW');
  assert.equal(run(base('defaults', { store: {}, languages: ['zh-CN'] })).targetLang, 'zh-CN');
  assert.equal(run(base('defaults', { store: {}, languages: ['fi-FI', 'ja-JP'] })).targetLang, 'zh-TW');
  // a mode chosen in the app is what shows, not the default
  const app = run(base('defaults', { store: {}, languages: ['ja-JP'], prefs: { mode: 'annotate', targetLang: 'ko', updatedAt: 3 } }));
  assert.deepEqual(app.checked, ['annotate']);
  assert.equal(app.targetLang, 'ko');
  assert.deepEqual(app.sentPrefs, []);
  assert.equal(app.stored.prefsUpdatedAt, 3);
});

test('a display change with nothing chosen stores neither mode, language nor level', () => {
  const r = run(base('display-change', { store: {}, languages: ['ja-JP'] }));
  assert.equal(r.stored.mergedMode, false);
  assert.equal(r.stored.prefsUpdatedAt, 0);
  for (const k of ['mode', 'targetLang', 'annotateLevel']) assert.ok(!(k in r.stored), k);
  assert.deepEqual(r.sentPrefs, []);
});

test('picking a mode in the switch is an explicit choice: stamped and sent to the app', () => {
  const r = run(base('pick-mode', { store: {}, languages: ['ko-KR'] }));
  assert.equal(r.sentPrefs.length, 1);
  assert.equal(r.sentPrefs[0].prefs.mode, 'translate');
  assert.equal(r.sentPrefs[0].prefs.targetLang, 'ko');
  assert.ok(r.sentPrefs[0].prefs.updatedAt > 0);
  assert.equal(r.stored.mode, 'translate');
  assert.ok(r.stored.prefsUpdatedAt > 0);
  assert.equal(r.engineCard, true); // an AI mode brings up the engine card
});

test('a size slider shows each step on the video while it moves, and is stored when let go', () => {
  const r = run(base('slider-drag'));
  assert.deepEqual(r.previews.map((m) => m.fontScale), [1.1, 1.2, 1.3]);
  assert.ok(r.previews.every((m) => m.bottomOffset === 10));
  assert.deepEqual(r.storedDuring, [1, 1, 1]); // nothing written mid-drag
  assert.equal(r.storedAfter, 1.3);
  assert.equal(r.shown, '130%');
});

console.log('\n' + passed + ' tests passed' + (process.exitCode ? ', some FAILED' : ''));

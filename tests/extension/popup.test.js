'use strict';
// Drives the real popup (extension/popup.html + popup.js + shared.js) in
// headless Chrome with a scripted browser API (popup/mock.js) and one
// scenario per page load (popup/driver.js).
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const assert = require('assert/strict');
const EXT = process.env.EXT || require('path').resolve(__dirname, '../../extension');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const HERE = path.join(__dirname, 'popup');

function run(cfg) {
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'mspopup-'));
  for (const f of ['popup.css', 'popup.js', 'shared.js']) fs.copyFileSync(path.join(EXT, f), path.join(dir, f));
  fs.copyFileSync(path.join(HERE, 'mock.js'), path.join(dir, 'mock.js'));
  fs.copyFileSync(path.join(HERE, 'driver.js'), path.join(dir, 'driver.js'));
  const html = fs.readFileSync(path.join(EXT, 'popup.html'), 'utf8')
    .replace('<script src="shared.js"></script>', '<script src="mock.js"></script><script src="shared.js"></script>')
    .replace('<script src="popup.js"></script>', '<script src="popup.js"></script><script src="driver.js"></script>');
  fs.writeFileSync(path.join(dir, 'popup.html'), html);
  const url = 'file://' + dir + '/popup.html#' + encodeURIComponent(JSON.stringify(cfg));
  const out = execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--user-data-dir=' + path.join(dir, 'prof'),
    '--virtual-time-budget=20000', '--dump-dom', url], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 60000 });
  fs.rmSync(dir, { recursive: true, force: true });
  const m = out.match(/@@OUT@@([\s\S]*?)@@END@@/);
  if (!m) throw new Error('no result in dumped DOM');
  const res = JSON.parse(m[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"'));
  if (!res.ok) throw new Error(res.error + ' log=' + JSON.stringify(res.log));
  return res.result;
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
const types = (sent) => sent.map((m) => m.type);

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('ok   ' + name); }
  catch (e) { console.log('FAIL ' + name + '\n     ' + (e.stack || e.message).split('\n').slice(0, 4).join('\n     ')); process.exitCode = 1; }
}

test('載入完整清單 lends the typed key to list-models only: no set-engine, key stays in the field', () => {
  const r = run(base('list-models', { requireConsent: true }));
  assert.deepEqual(r.sent, [{ type: 'list-models', provider: 'openai', apiKey: 'sk-typed' }]);
  assert.equal(r.keyField, 'sk-typed');
  assert.equal(r.result, '找到 2 個模型');
  assert.ok(r.options.includes('gpt-x'));
});

test('載入完整清單 without any key: asks for one instead of calling native', () => {
  const r = run(base('list-models-nokey'));
  assert.deepEqual(r.sent, []);
  assert.equal(r.result, '請先貼上 API Key');
});

test('儲存並測試: candidate test first, then the consent step (from consent-required), then set-engine with consent', () => {
  const r = run(base('save-consent', { requireConsent: true }));
  assert.deepEqual(r.step.sentBefore, [
    { type: 'test-engine', provider: 'openai', model: 'gpt-6-luna', apiKey: 'sk-typed' },
    { type: 'set-engine', engine: 'cloud', provider: 'openai', model: 'gpt-6-luna', apiKey: 'sk-typed' }
  ]);
  assert.equal(r.step.title, '測試成功（0.9 秒）');
  assert.equal(r.step.text, '按「同意並使用」後，要翻譯或標註的字幕文字會從這台 Mac 直接送到 OpenAI，不經過 MultiSub。');
  assert.equal(r.step.saveHidden, true);
  assert.deepEqual(r.sent.slice(2), [
    { type: 'set-engine', engine: 'cloud', provider: 'openai', model: 'gpt-6-luna', apiKey: 'sk-typed', consent: true }
  ]);
  assert.equal(r.notice, '✓ 可以用了（0.9 秒）');
  assert.equal(r.summary, 'OpenAI · gpt-6-luna');
  assert.equal(r.keyField, '');
  assert.equal(r.draftRemoved, true);
});

test('consent step for a custom endpoint names the address; 取消 saves nothing', () => {
  const r = run(base('save-consent-cancel', { providers: providers({ custom: { hasConsent: false } }) }));
  assert.equal(r.text, '按「同意並使用」後，要翻譯或標註的字幕文字會從這台 Mac 直接送到 你填的 API 網址（localhost:1234），不經過 MultiSub。');
  assert.deepEqual(r.sent, [{ type: 'test-engine', provider: 'custom', model: 'qwen3', baseURL: 'http://localhost:1234/v1' }]);
  assert.equal(r.stepHidden, true);
  assert.equal(r.result, '沒有儲存，原本的設定不變');
  assert.equal(r.formShown, true);
});

test('a failed candidate test saves nothing', () => {
  const r = run(base('save-test-fails', { replies: { 'test-engine': { ok: false, error: 'auth-failed', detail: '401' } } }));
  assert.deepEqual(types(r.sent), ['test-engine']);
  assert.equal(r.result, 'API Key 無效或已過期，請重新貼上');
  assert.match(r.cls, /err/);
});

test('儲存並測試 needs a key for hosted providers', () => {
  const r = run(base('save-nokey'));
  assert.deepEqual(r.sent, []);
  assert.equal(r.result, '請先貼上 API Key');
});

test('provider already consented: no step, set-engine without consent', () => {
  const r = run(base('save-known-consent', { requireConsent: true, providers: providers({ openai: { hasConsent: true } }) }));
  // (requireConsent in the mock would refuse it: it isn't asked here because it isn't needed)
  assert.deepEqual(types(r.sent).slice(0, 2), ['test-engine', 'set-engine']);
  assert.ok(!('consent' in r.sent[1]));
});

test('取得 API Key keeps a draft (provider/model, never the key) before the tab opens; reopening restores it', () => {
  const r = run(base('draft-keylink'));
  assert.equal(r.create.url, 'https://platform.openai.com/api-keys');
  assert.equal(r.create.draftAtCreate.provider, 'openai');
  assert.equal(r.create.draftAtCreate.model, 'gpt-6-luna');
  assert.ok(!JSON.stringify(r.stored).includes('sk-never-stored'));
  const r2 = run(base('draft-restore', { engine: engineCloud,
    store: Object.assign({}, translateSettings, { engineDraft: { provider: 'openai', model: 'gpt-6.1-terra', baseURL: '', savedAt: Date.now() } }) }));
  assert.equal(r2.provider, 'openai');
  assert.equal(r2.model, 'gpt-6.1-terra');
  assert.equal(r2.formShown, true); // reopened in edit mode although an engine is ready
  // a stale draft is ignored
  const r3 = run(base('draft-restore', { store: Object.assign({}, translateSettings, { engineDraft: { provider: 'openai', model: 'gpt-6.1-terra', savedAt: Date.now() - 2 * 3600e3 } }) }));
  assert.equal(r3.provider, 'anthropic');
});

test('Netflix tab without access (URL hidden): 允許存取 banner, no "open Netflix" status or button', () => {
  const r = run(base('perm', { permission: false, tabUrl: undefined, status: null }));
  assert.equal(r.banner, 'MultiSub 還沒有 Netflix 的存取權限');
  assert.equal(r.action, '允許存取');
  assert.equal(r.status, '允許存取 Netflix 後就會開始');
  assert.equal(r.openNetflixShown, false);
});

test('local-model link follows localModelDownloaded / active', () => {
  const r = run(base('local-downloaded', { engine: Object.assign({}, engineNone, { localModelDownloaded: true }) }));
  assert.equal(r.label, '改用本機模型（已下載，離線可用）');
  assert.deepEqual(r.sent[0], { type: 'set-engine', engine: 'local' });
  assert.ok(!types(r.sent).includes('open-app'));
  assert.equal(r.notice, '✓ 已改用本機模型，第一次載入約需 10–30 秒');
  assert.equal(r.summary, '本機模型 · gemma-4-e4b-it-4bit');
  const r2 = run(base('local-missing'));
  assert.equal(r2.label, '改用本機模型（離線，需先在 App 下載）');
  assert.deepEqual(r2.sent, [{ type: 'open-app', destination: 'engine' }]);
  const r3 = run(base('local-active', { engine: Object.assign({}, engineNone, { active: 'local', localModelDownloaded: true }) }));
  assert.equal(r3.useLocalShown, false);
  assert.equal(r3.cancelShown, true);
});

test('slow first ping: neutral loading state, then the real view', () => {
  const r = run(base('slow-ping', { pingDelay: 2000 }));
  assert.equal(r.snaps[0].loading, true);
  assert.equal(r.snaps[1].mainShown, true);
  assert.equal(r.snaps[1].engineCard, true);
  const r2 = run(base('very-slow-ping', { pingDelay: 4500, store: {} }));
  assert.equal(r2.a.chooserShown, true);
  assert.equal(r2.a.startDisabled, true); // the app may have a mode on its way
  assert.equal(r2.b.startDisabled, false);
});

console.log('\n' + passed + ' tests passed' + (process.exitCode ? ', some FAILED' : ''));

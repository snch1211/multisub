// Toolbar popup. Loaded after shared.js.
//
// A mode switch, the language/level pickers, one status line for the
// current Netflix tab, the AI engine card (AI modes only) and display
// settings tucked into a collapsed section. Nothing has to be chosen first:
// until the user picks something, the mode and language are shared.js's
// defaults (Netflix mode, the system language).
'use strict';

const api = typeof browser !== 'undefined' ? browser : chrome;
const MS = globalThis.MS;
const $ = (id) => document.getElementById(id);

const OTHER_MODEL = '__other__';
const AUTO_TRACK_VALUE = '__auto__';
const STATUS_POLL_MS = 2000;
const NATIVE_POLL_MS = 3000;
// How long the popup waits for the first native ping (a cold app extension
// can take a couple of seconds) before showing anything, so it doesn't show
// the default mode while the app's choice is on its way, or an empty engine
// card the ping is about to replace.
const FIRST_PING_WAIT_MS = 3000;
// storage.local key of the engine form's draft (see saveDraft); a draft
// older than the TTL is ignored.
const ENGINE_DRAFT_KEY = 'engineDraft';
const ENGINE_DRAFT_TTL_MS = 60 * 60 * 1000;
const NETFLIX_URL = /^https?:\/\/([^/]+\.)?netflix\.com\//i;

let settings = MS.mergeSettings(null);

const view = {
  tab: null,
  isNetflix: false,
  hasPermission: true,
  status: null, // last get-status reply from the Netflix tab
  statusFailed: false, // Netflix tab, but no content script answered
  nativeOk: null, // null until the first ping answers
  engine: null,
  engineOptions: null,
  engineOptionsPromise: null,
  engineEditing: false,
  formReady: false,
  extraModels: {}, // provider id -> model ids from list-models
  engineFlash: null, // { text, until }
  engineSavedAt: 0,
  pendingEngine: null, // { provider, candidate, latencyMs }: tested, waiting for the consent step
  draft: null, // { provider, model, baseURL, savedAt } from storage.local
  bannerKey: '',
  statusKey: '',
  tracksKey: ''
};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function send(msg) {
  try {
    return (await api.runtime.sendMessage(msg)) ||
      { ok: false, error: 'native-unavailable', detail: '背景程式沒有回應' };
  } catch (e) {
    return { ok: false, error: 'native-unavailable', detail: String(e && e.message || e) };
  }
}

function option(value, label) {
  const o = document.createElement('option');
  o.value = value;
  o.textContent = label;
  return o;
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------
// Unchosen preferences stay out of storage (see MS.storedSettings), so a
// display change doesn't freeze today's default second language.
function saveSettingsNow() {
  return api.storage.local.set({ settings: MS.storedSettings(settings) }).catch(() => {});
}

let saveTimer = null;
function saveSettingsSoon() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveSettingsNow, 150);
}

function sendPrefs() {
  send({ type: 'set-prefs', prefs: MS.prefsOf(settings) });
}

// mode / targetLang / annotateLevel are shared with the app: stamp them so
// the newest side wins, save at once and tell native.
function setPrefs(patch) {
  settings = Object.assign({}, settings, patch, { prefsUpdatedAt: Date.now() });
  saveSettingsNow();
  sendPrefs();
  render();
}

function stylesEqual(a, b) {
  return Object.keys(MS.DEFAULT_STYLES).every((k) => (a || {})[k] === (b || {})[k]);
}

// A drag on the Netflix overlay or the content script adopting the app's
// preferences writes storage.local directly; follow along while open.
api.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.settings) return;
  settings = MS.mergeSettings(changes.settings.newValue);
  render();
});

// ---------------------------------------------------------------------------
// Static controls
// ---------------------------------------------------------------------------
function buildStaticControls() {
  for (const lang of MS.LANGUAGES) $('targetLang').appendChild(option(lang.code, lang.label));
  for (const level of MS.LEVELS) $('annotateLevel').appendChild(option(level.id, level.label));

  const seg = $('modeSwitch');
  for (const m of MS.MODES) {
    const b = document.createElement('button');
    b.type = 'button';
    b.setAttribute('role', 'radio');
    b.dataset.mode = m.id;
    b.textContent = m.short;
    b.title = m.label;
    b.addEventListener('click', () => {
      if (settings.mode !== m.id) setPrefs({ mode: m.id });
    });
    seg.appendChild(b);
  }
  radioKeys(seg, (btn) => { if (settings.mode !== btn.dataset.mode) setPrefs({ mode: btn.dataset.mode }); });
}

// Arrow keys move between the radio buttons of a group (roving tabindex).
function radioKeys(group, choose) {
  group.addEventListener('keydown', (e) => {
    const keys = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
    if (!(e.key in keys)) return;
    const buttons = Array.from(group.querySelectorAll('[role="radio"]'));
    const i = buttons.indexOf(document.activeElement);
    if (i < 0) return;
    e.preventDefault();
    const next = buttons[(i + keys[e.key] + buttons.length) % buttons.length];
    choose(next);
    next.focus();
  });
}

function setRadioGroup(group, selectedId) {
  for (const b of group.querySelectorAll('[role="radio"]')) {
    const on = b.dataset.mode === selectedId;
    b.setAttribute('aria-checked', on ? 'true' : 'false');
    b.tabIndex = on ? 0 : -1;
  }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
function render() {
  $('enabled').checked = settings.enabled;
  renderMain();
  renderEngineCard();
  renderDisplaySettings();
  renderStatus();
}

function renderMain() {
  setRadioGroup($('modeSwitch'), settings.mode);
  const mode = MS.modeById(settings.mode);
  $('modeDesc').textContent = mode ? mode.desc : '';
  $('targetLang').value = settings.targetLang;
  $('annotateLevel').value = settings.annotateLevel;
  $('levelField').hidden = settings.mode !== 'annotate';
}

function renderDisplaySettings() {
  // Don't fight a slider the user is dragging right now.
  if (document.activeElement !== $('fontScale')) $('fontScale').value = settings.fontScale;
  if (document.activeElement !== $('bottomOffset')) $('bottomOffset').value = settings.bottomOffset;
  $('fontScaleValue').textContent = Math.round(settings.fontScale * 100) + '%';
  $('bottomOffsetValue').textContent = settings.bottomOffset + '%';
  // Annotate replaces the original line, so it always uses the merged layout.
  const annotate = settings.mode === 'annotate';
  const merged = $('mergedMode');
  merged.checked = annotate || !!settings.mergedMode;
  merged.disabled = annotate;
  merged.parentElement.classList.toggle('disabled', annotate);
  merged.parentElement.title = annotate ? '生字標註固定合併顯示' : '隱藏 Netflix 原本的字幕，兩行都由 MultiSub 顯示';
}

function setStatus(text, cls, action) {
  const key = text + '|' + (cls || '') + '|' + (action ? action.label : '');
  if (key === view.statusKey) return;
  view.statusKey = key;
  const node = $('statusText');
  node.textContent = text;
  node.className = 'status-text' + (cls ? ' ' + cls : '');
  const button = $('statusAction');
  button.hidden = !action;
  if (action) {
    button.textContent = action.label;
    button.onclick = action.run;
  } else {
    button.onclick = null;
  }
}

function renderStatus() {
  if (!settings.enabled) { setStatus('MultiSub 已關閉'); return; }
  // Without access Safari hides the tab's URL and no content script runs,
  // so this may well be a Netflix tab: don't tell the viewer to open one.
  if (!view.hasPermission) { setStatus('允許存取 Netflix 後就會開始'); return; }
  if (!view.isNetflix) { setStatus('打開 Netflix 播放影片就會開始'); return; }
  const st = view.status;
  if (!st) { setStatus(view.statusFailed ? '這個分頁還沒啟用 MultiSub' : '—'); return; }
  if (!st.onWatchPage) { setStatus('播放影片後就會顯示字幕'); return; }
  const lang = MS.languageName(settings.targetLang);
  const progress = st.totalCues ? ' ' + st.translatedCount + ' / ' + st.totalCues + ' 句' : '';
  switch (st.status) {
    case 'waiting-tracks':
    case 'fetching':
      setStatus('正在讀取字幕…');
      return;
    case 'ready':
      if (st.secondState === 'none') {
        setStatus('這部片沒有 Netflix 官方的' + lang + '字幕', '', {
          label: '改用 AI 翻譯', run: () => setPrefs({ mode: 'translate' })
        });
      } else if (st.secondState === 'failed') {
        setStatus('官方' + lang + '字幕讀取失敗', 'err', { label: '重新整理', run: reloadNetflixTab });
      } else {
        setStatus('Netflix 字幕已載入', 'ok');
      }
      return;
    case 'translating':
      setStatus('翻譯中' + progress);
      return;
    case 'annotating':
      setStatus('標註中' + progress);
      return;
    case 'done':
      if (st.partialMissing > 0 && st.totalCues) {
        const verb = st.jobKind === 'annotate' ? '標註' : '翻譯';
        setStatus('已' + verb + ' ' + (st.totalCues - st.partialMissing) + ' / ' + st.totalCues + ' 句，其餘稍後再試');
      } else {
        setStatus(st.jobKind === 'annotate' ? '標註完成' : '翻譯完成', 'ok');
      }
      return;
    case 'passthrough':
      setStatus('原文字幕已經是' + lang + '，不用' + (settings.mode === 'annotate' ? '標註' : '翻譯'));
      return;
    case 'fallback':
      if (settings.mode === 'netflix') {
        setStatus('沒有抓到字幕資料，請重新整理頁面', 'err', { label: '重新整理', run: reloadNetflixTab });
      } else if (st.errorCode) {
        setStatus(MS.errorText(st.errorCode), 'err');
      } else {
        setStatus(settings.mode === 'annotate' ? '沒抓到完整字幕，改成逐句標註' : '沒抓到完整字幕，改成逐句翻譯');
      }
      return;
    case 'error':
      // The overlay's wording points at this popup; here, point at the card.
      setStatus(st.errorCode === 'engine-not-ready' || st.errorCode === 'consent-required'
        ? '先在下面設定 AI 引擎' : MS.errorText(st.errorCode), 'err');
      return;
    default:
      setStatus('—');
  }
}

// One banner at most, most important first.
function renderBanner() {
  let text = '';
  let action = null;
  if (!view.hasPermission) {
    text = 'MultiSub 還沒有 Netflix 的存取權限';
    action = { label: '允許存取', run: requestNetflixAccess };
  } else if (view.isNetflix && view.statusFailed) {
    text = '需要重新整理 Netflix 分頁才能啟用 MultiSub';
    action = { label: '重新整理', run: reloadNetflixTab };
  } else if (view.nativeOk === false) {
    text = MS.errorText('native-unavailable') + (view.nativeDetail ? '（' + view.nativeDetail + '）' : '');
  }
  const key = text + '|' + (action ? action.label : '');
  if (key === view.bannerKey) return;
  view.bannerKey = key;
  $('banner').hidden = !text;
  $('bannerText').textContent = text;
  const button = $('bannerAction');
  button.hidden = !action;
  button.textContent = action ? action.label : '';
  button.onclick = action ? action.run : null;
}

// ---------------------------------------------------------------------------
// Netflix tab and diagnostics
// ---------------------------------------------------------------------------
async function activeTab() {
  try {
    const tabs = await api.tabs.query({ active: true, currentWindow: true });
    return tabs[0] || null;
  } catch (e) {
    return null;
  }
}

async function hasNetflixAccess() {
  try {
    if (!api.permissions || !api.permissions.contains) return true;
    return await api.permissions.contains({ origins: MS.NETFLIX_ORIGINS.slice() });
  } catch (e) {
    return true; // can't tell; don't nag
  }
}

// Must run synchronously inside the click: Safari only shows the permission
// prompt for a user gesture. Content scripts start on the next page load, so
// reload Netflix tabs once access is granted.
function requestNetflixAccess() {
  let request;
  try {
    request = api.permissions.request({ origins: MS.NETFLIX_ORIGINS.slice() });
  } catch (e) {
    return;
  }
  Promise.resolve(request).then(async (granted) => {
    if (!granted) return;
    view.hasPermission = true;
    renderBanner();
    let tabs = [];
    try { tabs = await api.tabs.query({ url: MS.NETFLIX_ORIGINS.slice() }); } catch (e) { /* ignore */ }
    for (const t of tabs) api.tabs.reload(t.id).catch(() => {});
  }).catch(() => {});
}

function reloadNetflixTab() {
  if (view.tab) api.tabs.reload(view.tab.id).catch(() => {});
}

async function refreshTab() {
  const tab = await activeTab();
  view.tab = tab;
  view.hasPermission = await hasNetflixAccess();
  let status = null;
  if (tab) {
    try { status = await api.tabs.sendMessage(tab.id, { type: 'get-status' }); } catch (e) { status = null; }
  }
  // tab.url is only visible with host access; an answering content script
  // proves it's Netflix either way.
  view.isNetflix = !!status || !!(tab && tab.url && NETFLIX_URL.test(tab.url));
  view.statusFailed = view.isNetflix && !status;
  view.status = status || null;
  $('openNetflix').hidden = view.isNetflix || !view.hasPermission;
  if (status) $('dragMode').checked = !!status.dragMode;
  renderBanner();
  renderStatus();
  renderTracks();
  updateOrganizeVocab();
}

function renderTracks() {
  const st = view.status;
  const tracks = st && st.onWatchPage && Array.isArray(st.tracks) ? st.tracks : [];
  $('trackField').hidden = !tracks.length;
  if (!tracks.length) return;
  const select = $('sourceTrack');
  const key = tracks.map((t) => t.id).join(',');
  if (key !== view.tracksKey) {
    view.tracksKey = key;
    select.textContent = '';
    select.appendChild(option(AUTO_TRACK_VALUE, '自動（跟著 Netflix）'));
    for (const t of tracks) {
      select.appendChild(option(t.id, t.label + (t.forced ? '（強制）' : '') + (/closed/i.test(t.trackType) ? '（CC）' : '')));
    }
  }
  if (document.activeElement !== select) {
    select.value = st.sourceMode === 'manual' && st.activeTrackId ? st.activeTrackId : AUTO_TRACK_VALUE;
  }
}

async function onTrackPicked() {
  if (!view.tab) return;
  const value = $('sourceTrack').value;
  try {
    if (value === AUTO_TRACK_VALUE) await api.tabs.sendMessage(view.tab.id, { type: 'set-track-auto' });
    else await api.tabs.sendMessage(view.tab.id, { type: 'set-track', trackId: value });
  } catch (e) { /* tab gone */ }
}

// The drag mode isn't a stored setting (it must not linger enabled across
// reloads); it lives in the Netflix tab's content script.
async function setDragMode(enabled) {
  if (!view.tab) return;
  try { await api.tabs.sendMessage(view.tab.id, { type: 'set-drag-mode', enabled: enabled }); } catch (e) { /* tab gone */ }
}

async function notifyEngineChanged() {
  let tabs = [];
  try { tabs = await api.tabs.query({ url: MS.NETFLIX_ORIGINS.slice() }); } catch (e) { /* ignore */ }
  if (!tabs.length && view.tab && view.isNetflix) tabs = [view.tab];
  for (const t of tabs) api.tabs.sendMessage(t.id, { type: 'engine-changed' }).catch(() => {});
}

// ---------------------------------------------------------------------------
// Native status
// ---------------------------------------------------------------------------
function engineSignature(engine) {
  if (!engine) return 'none';
  return [engine.active, engine.provider, engine.model, engine.hasKey, engine.localModelId].join('|');
}

async function refreshNative() {
  const sentAt = Date.now();
  const res = await send({ type: 'ping-native' });
  const wasOk = view.nativeOk;
  view.nativeOk = !!(res && res.ok);
  // Shown under the banner so a report from the field says *why*, not just
  // that the app couldn't be reached.
  view.nativeDetail = view.nativeOk ? '' : [res && res.error, res && res.detail].filter(Boolean).join('：');
  if (view.nativeOk) {
    let next = settings;
    if (res.styles && !stylesEqual(res.styles, settings.styles)) {
      next = Object.assign({}, next, { styles: Object.assign({}, MS.DEFAULT_STYLES, res.styles) });
    }
    const rec = MS.reconcilePrefs(next, res.prefs);
    if (rec.adopt) next = Object.assign({}, rec.adopt, { styles: next.styles });
    if (next !== settings) {
      settings = next;
      saveSettingsNow();
      render();
    }
    if (rec.push) sendPrefs();
    // A ping already in flight while the engine was saved carries the old
    // engine; don't let it flip the card back to the form.
    const fresh = sentAt >= view.engineSavedAt;
    const changed = fresh && engineSignature(res.engine) !== engineSignature(view.engine);
    if (fresh) view.engine = res.engine || null;
    if (changed || wasOk !== true) renderEngineCard();
  } else if (wasOk !== false) {
    renderEngineCard();
  }
  renderBanner();
}

// ---------------------------------------------------------------------------
// AI engine card
// ---------------------------------------------------------------------------
function engineReady() {
  return !!(view.engine && view.engine.active);
}

function providerById(id) {
  const opts = view.engineOptions;
  return opts && Array.isArray(opts.providers) ? opts.providers.find((p) => p.id === id) || null : null;
}

// Custom endpoints (LM Studio, Ollama, …) work without a key; every hosted
// provider needs one. Older native builds don't send keyRequired.
function keyRequired(p) {
  return typeof p.keyRequired === 'boolean' ? p.keyRequired : !p.needsBaseURL;
}

function hasSavedKey(p) {
  const e = view.engine;
  return p.hasKey === true || !!(e && e.provider === p.id && e.hasKey);
}

// Whether native has recorded the user's consent to send subtitles to `p`:
// true or false when the reply says so, null when it doesn't (then
// set-engine answering consent-required is what brings up the step).
function knownConsent(p) {
  if (typeof p.hasConsent === 'boolean') return p.hasConsent;
  const e = view.engine;
  if (e && e.provider === p.id && typeof e.hasConsent === 'boolean') return e.hasConsent;
  return null;
}

// Where subtitle text goes, named the way the privacy policy promises: the
// provider, or for a custom endpoint the address the user typed.
function destinationName(p, baseURL) {
  if (!p.needsBaseURL) return p.name;
  let host = '';
  try { host = baseURL ? new URL(baseURL).host : ''; } catch (e) { /* not a URL yet */ }
  return '你填的 API 網址' + (host ? '（' + host + '）' : '');
}

// Same wording as the app's engine status: "Anthropic Claude · claude-haiku-5-5".
// Recommended labels are only notes such as 「最快（推薦）」, so the model id
// is what names the model.
function engineSummary(engine) {
  if (engine.active === 'local') {
    const id = String(engine.localModelId || '');
    const name = id.split('/').pop();
    return '本機模型' + (name ? ' · ' + name : '');
  }
  const p = providerById(engine.provider);
  const providerName = engine.providerName || (p && p.name) || engine.provider || '';
  return [providerName, String(engine.model || '')].filter(Boolean).join(' · ');
}

// The summary may be cut off at 340 px; the tooltip shows all of it.
function showEngineSummary() {
  const node = $('engineSummaryText');
  node.textContent = engineSummary(view.engine);
  node.title = node.textContent;
}

function loadEngineOptions() {
  if (view.engineOptions) return Promise.resolve(view.engineOptions);
  if (!view.engineOptionsPromise) {
    view.engineOptionsPromise = send({ type: 'get-engine-options' }).then((res) => {
      view.engineOptionsPromise = null;
      if (res && res.ok && Array.isArray(res.providers) && res.providers.length) {
        view.engineOptions = res;
        if (res.engine && !view.engine) view.engine = res.engine;
        return res;
      }
      throw Object.assign(new Error('options'), { code: (res && res.error) || 'provider-error' });
    });
  }
  return view.engineOptionsPromise;
}

function setEngineResult(text, cls) {
  const node = $('engineResult');
  node.textContent = text || '';
  node.className = 'engine-result' + (cls ? ' ' + cls : '');
}

function renderEngineCard() {
  const mode = MS.modeById(settings.mode);
  const show = !!mode && mode.needsEngine;
  $('engineCard').hidden = !show;
  if (!show) return;
  const notice = $('engineNotice');
  if (view.nativeOk !== true) {
    // Nothing to show yet, or nothing reachable: one line instead of an
    // empty card or a form that couldn't save anyway.
    $('engineSummary').hidden = true;
    $('engineForm').hidden = true;
    notice.hidden = false;
    const failed = view.nativeOk === false;
    notice.textContent = failed ? MS.errorText('native-unavailable') : '載入中…';
    notice.className = 'engine-notice ' + (failed ? 'err' : 'dim');
    // formReady is left alone: when native answers again, a half-filled
    // form comes back as it was.
    return;
  }
  const ready = engineReady();
  const editing = !ready || view.engineEditing;
  $('engineSummary').hidden = editing;
  $('engineForm').hidden = !editing;
  $('engineCancel').hidden = !ready;
  const flash = view.engineFlash && Date.now() < view.engineFlash.until ? view.engineFlash : null;
  notice.hidden = editing || !flash;
  if (flash) {
    notice.textContent = flash.text;
    notice.className = 'engine-notice';
  }
  if (!editing) {
    showEngineSummary();
    // Provider names for the summary come from the options; fetch them once.
    if (!view.engineOptions) {
      loadEngineOptions().then(showEngineSummary).catch(() => {});
    }
    view.formReady = false;
    return;
  }
  renderUseLocal();
  if (!view.formReady) prepareEngineForm();
}

// The local-model link says what it will do: switch right away when the
// model is already downloaded, otherwise send the viewer to the app, which
// shows the download size for the model it will fetch. Hidden while the
// local model is what's running (取消 keeps it).
function renderUseLocal() {
  const e = view.engine || {};
  const link = $('useLocal');
  link.hidden = e.active === 'local';
  link.textContent = e.localModelDownloaded ? '改用本機模型（已下載，離線可用）' : '改用本機模型（離線，需先在 App 下載）';
}

async function prepareEngineForm() {
  view.formReady = true;
  if (!view.engineOptions) setEngineResult('載入中…');
  try {
    await loadEngineOptions();
  } catch (e) {
    view.formReady = false;
    setEngineResult(MS.errorText(e.code), 'err');
    return;
  }
  setEngineResult('');
  const providers = view.engineOptions.providers;
  const select = $('provider');
  select.textContent = '';
  for (const p of providers) select.appendChild(option(p.id, p.name));
  // A draft (the user went to fetch a key, which closes the popup) wins over
  // the saved provider, so they come back to the form they left.
  const draft = view.draft && providerById(view.draft.provider) ? view.draft : null;
  const saved = view.engine && providerById(view.engine.provider) ? view.engine.provider : providers[0].id;
  select.value = draft ? draft.provider : saved;
  onProviderChanged(draft);
}

function currentProvider() {
  return providerById($('provider').value);
}

function onProviderChanged(draft) {
  const p = currentProvider();
  if (!p) return;
  cancelConsentStep();
  const engine = view.engine || {};
  const same = engine.provider === p.id;
  const fromDraft = draft && draft.provider === p.id ? draft : null;
  const key = $('apiKey');
  key.value = '';
  key.placeholder = hasSavedKey(p) ? '已儲存，留空就沿用' : (p.keyPlaceholder || '');
  $('keyLink').hidden = !p.keyURL;
  $('baseURLField').hidden = !p.needsBaseURL;
  if (p.needsBaseURL) {
    if (fromDraft) $('baseURL').value = fromDraft.baseURL || '';
    else if (same && engine.baseURL) $('baseURL').value = engine.baseURL;
  }
  const model = fromDraft && fromDraft.model ? fromDraft.model : (same && engine.model ? engine.model : p.defaultModel);
  fillModelSelect(p, model);
  // The privacy policy promises the provider is named before any subtitle
  // text goes to it; the confirmation step after the test names it again.
  $('engineDisclosure').textContent = '儲存後，要翻譯或標註的字幕文字會從這台 Mac 直接送到 ' +
    destinationName(p, '') + '，不經過 MultiSub。';
  setEngineResult('');
}

function fillModelSelect(p, selected) {
  const select = $('model');
  const custom = $('modelCustom');
  select.textContent = '';
  const recommended = Array.isArray(p.recommended) ? p.recommended : [];
  const ids = recommended.map((r) => r.id);
  for (const r of recommended) select.appendChild(option(r.id, r.label ? r.id + ' · ' + r.label : r.id));
  const extra = (view.extraModels[p.id] || []).filter((id) => !ids.includes(id));
  if (extra.length) {
    const group = document.createElement('optgroup');
    group.label = '完整清單';
    for (const id of extra) group.appendChild(option(id, id));
    select.appendChild(group);
  }
  select.appendChild(option(OTHER_MODEL, '其他…'));
  const known = ids.concat(extra);
  // A provider with no suggestions (custom endpoints) only gets the text box.
  select.hidden = !known.length;
  if (selected && known.includes(selected)) {
    select.value = selected;
    custom.hidden = true;
  } else {
    select.value = OTHER_MODEL;
    custom.hidden = false;
    custom.value = selected && !known.includes(selected) ? selected : '';
  }
}

function selectedModel() {
  const select = $('model');
  if (!select.hidden && select.value !== OTHER_MODEL) return select.value;
  return $('modelCustom').value.trim();
}

// --- Draft of the form (provider, model, base URL; never the key) --------
// 「取得 API Key」 opens a tab, and Safari closes the popup when it does;
// without this the form would come back on the saved provider and a key
// pasted for another provider would be stored under the wrong one.
async function loadDraft() {
  try {
    const res = await api.storage.local.get(ENGINE_DRAFT_KEY);
    const d = res && res[ENGINE_DRAFT_KEY];
    if (d && typeof d.provider === 'string' && Date.now() - (Number(d.savedAt) || 0) < ENGINE_DRAFT_TTL_MS) return d;
  } catch (e) { /* no draft */ }
  return null;
}

function saveDraft() {
  const p = currentProvider();
  if (!p) return Promise.resolve();
  const draft = {
    provider: p.id,
    model: selectedModel(),
    baseURL: p.needsBaseURL ? $('baseURL').value.trim() : '',
    savedAt: Date.now()
  };
  view.draft = draft;
  try {
    return Promise.resolve(api.storage.local.set({ [ENGINE_DRAFT_KEY]: draft })).catch(() => {});
  } catch (e) {
    return Promise.resolve();
  }
}

let draftTimer = null;
function saveDraftSoon() {
  clearTimeout(draftTimer);
  draftTimer = setTimeout(saveDraft, 300);
}

function clearDraft() {
  clearTimeout(draftTimer);
  view.draft = null;
  try { Promise.resolve(api.storage.local.remove(ENGINE_DRAFT_KEY)).catch(() => {}); } catch (e) { /* nothing stored */ }
}

// Engine requests come back from native as-is. Codes outside ERROR_TEXT
// (bad-request, keychain-failed, …) carry a readable zh-TW detail, which says
// more than a generic message would; so does engine-not-ready from a test
// or a model list (e.g. 「還沒儲存這個 AI 服務的 API Key。」), where the
// generic text would point back at this very popup.
function testErrorText(res) {
  const code = res && res.error;
  const detail = res && res.detail ? String(res.detail).slice(0, 120) : '';
  if (detail && (!MS.ERROR_TEXT[code] || code === 'engine-not-ready')) return detail;
  const text = MS.errorText(code);
  return code === 'provider-error' && detail ? text + '：' + detail : text;
}

// 儲存並測試: test the setup exactly as typed (the key is only lent to the
// test), and save nothing unless it works, so a wrong key or model never
// replaces an engine that was working. Then the consent step, then save.
async function onSaveEngine(e) {
  e.preventDefault();
  if (view.pendingEngine) return; // the confirmation step is up
  const p = currentProvider();
  if (!p) return;
  const model = selectedModel();
  const baseURL = p.needsBaseURL ? $('baseURL').value.trim() : null;
  const apiKey = $('apiKey').value.trim();
  if (!model) { setEngineResult('請選擇或輸入模型', 'err'); return; }
  if (p.needsBaseURL && !baseURL) { setEngineResult('請填 API 網址', 'err'); return; }
  if (keyRequired(p) && !apiKey && !hasSavedKey(p)) {
    setEngineResult('請先貼上 API Key', 'err');
    $('apiKey').focus();
    return;
  }
  // Keep the form up while testing and saving, whatever the status poll sees.
  view.engineEditing = true;
  const button = $('saveEngine');
  button.disabled = true;
  button.textContent = '測試中…';
  setEngineResult('');
  const candidate = { provider: p.id, model: model };
  // Only an endpoint that needs it gets a base URL, so switching providers
  // doesn't wipe a saved custom endpoint.
  if (baseURL != null) candidate.baseURL = baseURL;
  if (apiKey) candidate.apiKey = apiKey; // left out: native tests the saved key
  try {
    const test = await send(Object.assign({ type: 'test-engine' }, candidate));
    if (!test || !test.ok) { setEngineResult(testErrorText(test), 'err'); return; }
    view.pendingEngine = { provider: p, candidate: candidate, latencyMs: Number(test.latencyMs) || 0 };
    if (knownConsent(p) === false) showConsentStep();
    else await commitEngine(false);
  } finally {
    button.disabled = false;
    button.textContent = '儲存並測試';
  }
}

// Saves the tested candidate. Without `consent`, native refuses a provider
// the user hasn't agreed to yet (consent-required, nothing changed), which
// brings up the confirmation step; its 「同意並使用」 calls this again with
// consent, which native records.
async function commitEngine(consent) {
  const pending = view.pendingEngine;
  if (!pending) return;
  const c = pending.candidate;
  const req = { type: 'set-engine', engine: 'cloud', provider: c.provider, model: c.model };
  if (c.baseURL != null) req.baseURL = c.baseURL;
  if (c.apiKey) req.apiKey = c.apiKey;
  if (consent) req.consent = true;
  const res = await send(req);
  if (!res || !res.ok) {
    if (res && res.error === 'consent-required' && !consent) { showConsentStep(); return; }
    view.pendingEngine = null;
    hideConsentStep();
    setEngineResult(testErrorText(res), 'err');
    return;
  }
  view.pendingEngine = null;
  hideConsentStep();
  if (res.engine) {
    view.engine = res.engine;
    view.engineSavedAt = Date.now();
  }
  // view.engineOptions isn't fetched again; keep what it says current.
  pending.provider.hasConsent = true;
  if (c.apiKey) pending.provider.hasKey = true;
  $('apiKey').value = '';
  clearDraft();
  view.engineEditing = false;
  const sec = (pending.latencyMs / 1000).toFixed(1);
  view.engineFlash = { text: '✓ 可以用了（' + sec + ' 秒）', until: Date.now() + 10000 };
  notifyEngineChanged();
  renderEngineCard();
}

// Explicit confirmation (App Review 5.1.2(i)) that names where subtitle text
// will go before the first request is sent there.
function showConsentStep() {
  const pending = view.pendingEngine;
  if (!pending) return;
  const sec = (pending.latencyMs / 1000).toFixed(1);
  $('consentTitle').textContent = '測試成功（' + sec + ' 秒）';
  $('consentText').textContent = '按「同意並使用」後，要翻譯或標註的字幕文字會從這台 Mac 直接送到 ' +
    destinationName(pending.provider, pending.candidate.baseURL) + '，不經過 MultiSub。';
  $('consentStep').hidden = false;
  $('saveEngine').hidden = true;
  $('engineDisclosure').hidden = true;
  setEngineResult('');
  $('consentAccept').focus();
}

function hideConsentStep() {
  $('consentStep').hidden = true;
  $('saveEngine').hidden = false;
  $('engineDisclosure').hidden = false;
}

// Editing the form (or leaving it) drops a pending confirmation: what was
// tested is no longer what would be saved.
function cancelConsentStep() {
  if (!view.pendingEngine) return;
  view.pendingEngine = null;
  hideConsentStep();
}

async function onConsentAccept() {
  const button = $('consentAccept');
  button.disabled = true;
  button.textContent = '儲存中…';
  try {
    await commitEngine(true);
  } finally {
    button.disabled = false;
    button.textContent = '同意並使用';
  }
}

function onConsentCancel() {
  cancelConsentStep();
  setEngineResult('沒有儲存，原本的設定不變');
}

async function onLoadModels() {
  const p = currentProvider();
  if (!p) return;
  const apiKey = $('apiKey').value.trim();
  if (p.needsBaseURL && !$('baseURL').value.trim()) { setEngineResult('請填 API 網址', 'err'); return; }
  if (keyRequired(p) && !apiKey && !hasSavedKey(p)) { setEngineResult('請先貼上 API Key', 'err'); return; }
  const link = $('loadModels');
  link.disabled = true;
  setEngineResult('載入中…');
  try {
    // /models needs the key. A freshly typed one is lent to this request
    // only: native neither saves it nor switches the engine, so browsing
    // models can't start sending subtitles anywhere. Only 儲存並測試 saves.
    const req = { type: 'list-models', provider: p.id };
    if (p.needsBaseURL) req.baseURL = $('baseURL').value.trim();
    if (apiKey) req.apiKey = apiKey;
    const res = await send(req);
    if (!res || !res.ok || !Array.isArray(res.models)) { setEngineResult(testErrorText(res), 'err'); return; }
    const ids = res.models.map((m) => (typeof m === 'string' ? m : m && m.id)).filter(Boolean).sort();
    view.extraModels[p.id] = ids;
    fillModelSelect(p, selectedModel());
    setEngineResult('找到 ' + ids.length + ' 個模型');
  } finally {
    link.disabled = false;
  }
}

async function onUseLocal() {
  const e = view.engine || {};
  if (!e.localModelDownloaded) {
    const res = await send({ type: 'open-app', destination: 'engine' });
    if (res && res.ok) setEngineResult('已打開 MultiSub App，在 App 裡下載模型就能用');
    else setEngineResult('打不開 MultiSub App，請確認已安裝', 'err');
    return;
  }
  cancelConsentStep();
  const link = $('useLocal');
  link.disabled = true;
  let res;
  try {
    res = await send({ type: 'set-engine', engine: 'local' });
  } finally {
    link.disabled = false;
  }
  if (!res || !res.ok) { setEngineResult(testErrorText(res), 'err'); return; }
  if (res.engine) {
    view.engine = res.engine;
    view.engineSavedAt = Date.now();
  }
  clearDraft();
  view.engineEditing = false;
  // No test from here: a first local load takes 10-30 s, longer than Safari
  // keeps the background page alive for a pending native call.
  view.engineFlash = { text: '✓ 已改用本機模型，第一次載入約需 10–30 秒', until: Date.now() + 10000 };
  notifyEngineChanged();
  renderEngineCard();
}

async function openKeyPage() {
  const p = currentProvider();
  if (!p || !p.keyURL) return;
  await saveDraft(); // the popup closes as soon as the tab opens
  api.tabs.create({ url: p.keyURL }).catch(() => {});
}

// ---------------------------------------------------------------------------
// Vocabulary and styles
// ---------------------------------------------------------------------------
function updateOrganizeVocab() {
  const button = $('organizeVocab');
  const hint = $('organizeVocabHint');
  const st = view.status;
  const tracks = st && st.onWatchPage && Array.isArray(st.tracks) ? st.tracks : [];
  const active = tracks.find((t) => t.id === st.activeTrackId);
  // Gated on the track's language tag (primary subtag), same check as content.js.
  const english = !!active && MS.normalizeBcp47(active.language) === 'en';
  button.disabled = !english;
  const reason = '生詞本只支援英文字幕';
  // Only touch the hint for this reason, never a click-triggered error.
  if (!english && tracks.length) {
    hint.textContent = reason;
    hint.className = 'hint';
  } else if (english && hint.textContent === reason) {
    hint.textContent = '';
  }
}

function organizeVocabErrorText(code) {
  switch (code) {
    case 'non-english': return '生詞本只支援英文字幕';
    case 'no-episode': return '等字幕載入後再試一次';
    case 'open-failed': return '打不開 MultiSub App，請確認已安裝';
    case 'native-unavailable': return MS.errorText(code);
    default: return '整理失敗，請再試一次（' + (code || 'unknown') + '）';
  }
}

async function onOrganizeVocab() {
  const hint = $('organizeVocabHint');
  hint.textContent = '';
  hint.className = 'hint';
  if (!view.tab) return;
  try {
    const res = await api.tabs.sendMessage(view.tab.id, { type: 'organize-vocab' });
    if (!res || !res.ok) {
      hint.textContent = organizeVocabErrorText(res && res.error);
      hint.className = 'hint err';
    }
  } catch (e) {
    hint.textContent = '連不到 Netflix 分頁';
    hint.className = 'hint err';
  }
}

async function onOpenStyles() {
  const hint = $('openStylesHint');
  hint.textContent = '';
  hint.className = 'hint';
  const res = await send({ type: 'open-app' });
  if (!res || !res.ok) {
    hint.textContent = '打不開 MultiSub App，請確認已安裝';
    hint.className = 'hint err';
  }
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------
function bindEvents() {
  $('enabled').addEventListener('change', (e) => {
    settings = Object.assign({}, settings, { enabled: e.target.checked });
    saveSettingsNow();
    render();
  });

  $('targetLang').addEventListener('change', (e) => setPrefs({ targetLang: e.target.value }));
  $('annotateLevel').addEventListener('change', (e) => setPrefs({ annotateLevel: e.target.value }));

  $('engineChange').addEventListener('click', () => {
    view.engineEditing = true;
    view.formReady = false;
    renderEngineCard();
  });
  $('engineCancel').addEventListener('click', () => {
    cancelConsentStep();
    clearDraft();
    view.engineEditing = false;
    renderEngineCard();
  });
  $('provider').addEventListener('change', () => onProviderChanged(null));
  // Any edit invalidates a pending confirmation, and the choices so far are
  // kept as a draft (see saveDraft).
  const onFormEdit = (e) => {
    if ($('consentStep').contains(e.target)) return;
    cancelConsentStep();
    if (['provider', 'model', 'modelCustom', 'baseURL'].includes(e.target.id)) saveDraftSoon();
  };
  $('engineForm').addEventListener('input', onFormEdit);
  $('engineForm').addEventListener('change', onFormEdit);
  $('consentAccept').addEventListener('click', onConsentAccept);
  $('consentCancel').addEventListener('click', onConsentCancel);
  $('model').addEventListener('change', () => {
    const other = $('model').value === OTHER_MODEL;
    $('modelCustom').hidden = !other;
    if (other) $('modelCustom').focus();
  });
  $('keyLink').addEventListener('click', openKeyPage);
  $('loadModels').addEventListener('click', onLoadModels);
  $('engineForm').addEventListener('submit', onSaveEngine);
  $('useLocal').addEventListener('click', onUseLocal);

  $('fontScale').addEventListener('input', (e) => {
    settings = Object.assign({}, settings, { fontScale: parseFloat(e.target.value) });
    $('fontScaleValue').textContent = Math.round(settings.fontScale * 100) + '%';
    saveSettingsSoon();
  });
  $('bottomOffset').addEventListener('input', (e) => {
    settings = Object.assign({}, settings, { bottomOffset: parseInt(e.target.value, 10) });
    $('bottomOffsetValue').textContent = settings.bottomOffset + '%';
    saveSettingsSoon();
  });
  $('mergedMode').addEventListener('change', (e) => {
    settings = Object.assign({}, settings, { mergedMode: e.target.checked });
    saveSettingsNow();
  });
  $('dragMode').addEventListener('change', (e) => setDragMode(e.target.checked));
  $('sourceTrack').addEventListener('change', onTrackPicked);
  $('openStyles').addEventListener('click', onOpenStyles);
  $('organizeVocab').addEventListener('click', onOrganizeVocab);
  $('openNetflix').addEventListener('click', () => {
    api.tabs.create({ url: 'https://www.netflix.com/' }).catch(() => {});
  });
}

async function init() {
  buildStaticControls();
  bindEvents();
  try {
    const res = await api.storage.local.get('settings');
    settings = MS.mergeSettings(res && res.settings);
  } catch (e) { /* defaults */ }
  view.draft = await loadDraft();
  // Back from fetching a key: reopen the form the viewer left.
  if (view.draft) view.engineEditing = true;
  // Wait for the first ping (and the tab check) behind a neutral loading
  // line, so a mode or language chosen in the app is adopted before the
  // switch shows the default, and the engine card and status line don't
  // show a state that's about to change.
  await Promise.race([Promise.all([refreshNative(), refreshTab()]), sleep(FIRST_PING_WAIT_MS)]);
  render();
  document.body.classList.remove('loading');
  setInterval(refreshTab, STATUS_POLL_MS);
  setInterval(refreshNative, NATIVE_POLL_MS);
  // Fades the "✓ 可以用了" line out on schedule.
  setInterval(() => {
    if (view.engineFlash && Date.now() >= view.engineFlash.until) {
      view.engineFlash = null;
      renderEngineCard();
    }
  }, 1000);
}

init();

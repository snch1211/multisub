// Toolbar popup. Loaded after shared.js.
//
// A mode switch, the language/level pickers, one status line for the
// current Netflix tab, the AI engine's status (AI modes only; it is set up
// in the app) and display settings tucked into a collapsed section. Nothing has to be chosen first:
// until the user picks something, the mode and language are shared.js's
// defaults (Netflix mode, the system language).
'use strict';

const api = typeof browser !== 'undefined' ? browser : chrome;
const MS = globalThis.MS;
const $ = (id) => document.getElementById(id);

const AUTO_TRACK_VALUE = '__auto__';
const STATUS_POLL_MS = 2000;
const NATIVE_POLL_MS = 3000;
// How long the popup waits for the first native ping (a cold app extension
// can take a couple of seconds) before showing anything, so it doesn't show
// the default mode while the app's choice is on its way, or an empty engine
// card the ping is about to replace.
const FIRST_PING_WAIT_MS = 3000;
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
  engineOpenNote: null, // { text, err }: what 打開 App 設定 last reported
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
  // The status line would otherwise show the old mode's state until the
  // next poll; ask the tab again as soon as it has switched.
  saveSettingsNow().then(refreshTabSoon);
  sendPrefs();
  render();
}

// Twice: the tab normally switches within a few ms of the write, but
// storage.onChanged reaches it on its own schedule.
let refreshTabTimers = [];
function refreshTabSoon() {
  for (const t of refreshTabTimers) clearTimeout(t);
  refreshTabTimers = [80, 500].map((ms) => setTimeout(refreshTab, ms));
}

// While a size or position slider moves, the Netflix tab shows each value
// right away (preview-display); storage.local, which every tab follows, is
// written once the slider settles. A slider only has 30-40 steps, so one
// message per step is cheap.
function previewDisplay() {
  if (!view.tab || !view.isNetflix) return;
  try {
    Promise.resolve(api.tabs.sendMessage(view.tab.id, {
      type: 'preview-display', fontScale: settings.fontScale, bottomOffset: settings.bottomOffset
    })).catch(() => {});
  } catch (e) { /* tab gone */ }
}

// Past Safari's height limit (about 600 px) the popup scrolls instead of
// growing, without a scrollbar (see popup.css). A fade along the bottom
// edge then says there is more below; it goes once the bottom is reached.
function updateMoreBelow() {
  const page = document.scrollingElement || document.documentElement;
  const more = page.scrollHeight - page.clientHeight - page.scrollTop > 2;
  document.body.classList.toggle('more-below', more);
}

// Past Safari's height limit (about 600 px) the popup scrolls instead of
// growing. Opening the display settings scrolls down as far as it can while
// keeping their header in view, so what's below them shows too.
function revealDisplaySettings() {
  const details = $('displaySettings');
  if (!details.open) return;
  const page = document.scrollingElement || document.documentElement;
  const maxTop = page.scrollHeight - page.clientHeight;
  const top = Math.min(maxTop, details.offsetTop - 8);
  if (top <= page.scrollTop) return;
  const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  page.scrollTo({ top: top, behavior: reduce ? 'auto' : 'smooth' });
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
  if (!st) {
    setStatus(view.statusFailed
      ? '這個分頁還沒啟用 MultiSub' + (view.statusDetail ? '（' + view.statusDetail + '）' : '')
      : '—');
    return;
  }
  if (!st.onWatchPage) { setStatus('播放影片後就會顯示字幕'); return; }
  // A mode was just picked and the tab hasn't answered for it yet: its
  // last reply is about the mode before.
  if (st.mode && st.mode !== settings.mode) { setStatus('切換中…'); return; }
  const lang = MS.languageName(settings.targetLang);
  const progress = st.totalCues ? ' ' + st.translatedCount + ' / ' + st.totalCues + ' 句' : '';
  switch (st.status) {
    case 'waiting-tracks':
    case 'fetching':
      setStatus('正在讀取字幕…');
      return;
    case 'ready':
      if (st.secondState === 'none') {
        setStatus('這部片沒有官方' + lang + '字幕', '', {
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
    case 'done': {
      const annotate = (st.jobKind || st.mode) === 'annotate';
      if (st.partialMissing > 0 && st.totalCues) {
        const verb = annotate ? '標註' : '翻譯';
        setStatus('已' + verb + ' ' + (st.totalCues - st.partialMissing) + ' / ' + st.totalCues + ' 句，其餘稍後補上');
      } else {
        setStatus(annotate ? '標註完成' : '翻譯完成', 'ok');
      }
      return;
    }
    case 'passthrough':
      setStatus('原文已經是' + lang + '，不用' + (settings.mode === 'annotate' ? '標註' : '翻譯'));
      return;
    case 'fallback':
      if (settings.mode === 'netflix') {
        setStatus('沒抓到字幕，請重新整理頁面', 'err', { label: '重新整理', run: reloadNetflixTab });
      } else if (st.errorCode) {
        setStatus(MS.errorText(st.errorCode), 'err');
      } else {
        setStatus(settings.mode === 'annotate' ? '沒抓到完整字幕，改為逐句標註' : '沒抓到完整字幕，改為逐句翻譯');
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
    text = '重新整理 Netflix 分頁後才會啟用';
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
  let detail = '';
  if (tab) {
    try {
      status = await api.tabs.sendMessage(tab.id, { type: 'get-status' });
      if (!status) detail = '分頁沒有回應';
    } catch (e) {
      status = null;
      detail = String((e && e.message) || e);
    }
  }
  // Shown after 「這個分頁還沒啟用 MultiSub」 so a report from the field says
  // why the tab didn't answer.
  view.statusDetail = status ? '' : detail;
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
    const changed = engineSignature(res.engine) !== engineSignature(view.engine);
    const known = view.engine !== null;
    view.engine = res.engine || null;
    if (changed || wasOk !== true) {
      view.engineOpenNote = null;
      renderEngineCard();
    }
    // Set up in the app since the last answer (the viewer went there from
    // this card and came back): a tab whose job failed for lack of an
    // engine retries now instead of on its next ping, up to a minute away.
    if (changed && known && engineReady()) notifyEngineChanged();
  } else if (wasOk !== false) {
    renderEngineCard();
  }
  renderBanner();
}

// ---------------------------------------------------------------------------
// AI engine card
// ---------------------------------------------------------------------------
// Only what the engine is, or that there isn't one yet. Setting it up
// (provider, API key, model, the local model, the test and the consent to
// send subtitles) happens in the app, which has the room for it; the popup
// sends the viewer there.
function engineReady() {
  return !!(view.engine && view.engine.active);
}

// Same wording as the app's engine status: "Anthropic Claude · claude-haiku-5-5".
function engineSummary(engine) {
  if (engine.active === 'local') {
    const id = String(engine.localModelId || '');
    const name = id.split('/').pop();
    return '本機模型' + (name ? ' · ' + name : '');
  }
  const providerName = engine.providerName || engine.provider || '';
  return [providerName, String(engine.model || '')].filter(Boolean).join(' · ');
}

// Why there's no engine yet, in the terms of what to do in the app.
function engineMissingText(engine) {
  if (engine && engine.configured === 'local' && !engine.localModelDownloaded) {
    return '本機模型還沒下載，到 MultiSub App 下載後就能用';
  }
  return 'AI 翻譯和生字標註需要 AI 引擎，在 MultiSub App 設定';
}

function renderEngineCard() {
  const mode = MS.modeById(settings.mode);
  const show = !!mode && mode.needsEngine;
  $('engineCard').hidden = !show;
  if (!show) return;
  const notice = $('engineNotice');
  const ready = view.nativeOk === true && engineReady();
  const missing = view.nativeOk === true && !ready;
  $('engineSummary').hidden = !ready;
  $('engineSetup').hidden = !missing;
  if (ready) {
    // The summary may be cut off at 340 px; the tooltip shows all of it.
    const node = $('engineSummaryText');
    node.textContent = engineSummary(view.engine);
    node.title = node.textContent;
  }
  if (missing) $('engineSetupText').textContent = engineMissingText(view.engine);
  // Nothing to show yet, or nothing reachable: one line instead.
  const note = view.nativeOk !== true
    ? { text: view.nativeOk === false ? MS.errorText('native-unavailable') : '載入中…', cls: view.nativeOk === false ? 'err' : 'dim' }
    : view.engineOpenNote ? { text: view.engineOpenNote.text, cls: view.engineOpenNote.err ? 'err' : 'dim' } : null;
  notice.hidden = !note;
  if (note) {
    notice.textContent = note.text;
    notice.className = 'engine-notice ' + note.cls;
  }
}

// Opens the app on its engine settings. Safari usually closes the popup as
// the app comes forward; when it doesn't, the card says what happened.
async function openEngineSetup() {
  const res = await send({ type: 'open-app', destination: 'general' });
  view.engineOpenNote = res && res.ok
    ? { text: '已打開 MultiSub App，設定好後回來就能用', err: false }
    : { text: '打不開 MultiSub App，請確認已安裝', err: true };
  renderEngineCard();
}

// ---------------------------------------------------------------------------
// Vocabulary and styles
// ---------------------------------------------------------------------------

// 整理本集單字 hands the transcript to the app, which may well stay behind
// Safari, so the popup follows the work itself: the app writes where each
// episode stands to the shared container and native `vocab-status` reads it
// back. `status` is that reply for the episode in the tab ({state, done,
// total, wordCount, code, message}), or {state: 'handing-off'} while the
// click is still out; null shows nothing. `openNote` is what 打開生詞本
// last reported, shown until the status changes.
const vocabView = {
  movieId: null,
  status: null,
  inFlight: false,
  openNote: '',
  openNoteErr: false
};
const VOCAB_ACTIVE_STATES = ['handing-off', 'queued', 'running'];

function vocabActive() {
  return !!vocabView.status && VOCAB_ACTIVE_STATES.includes(vocabView.status.state);
}

// Runs on every tab poll (STATUS_POLL_MS): asks once for a newly seen
// episode, then keeps asking only while its work is queued or running.
function updateOrganizeVocab() {
  const st = view.status;
  const movieId = st && st.onWatchPage && st.movieId ? String(st.movieId) : null;
  if (movieId !== vocabView.movieId) {
    vocabView.movieId = movieId;
    vocabView.status = null;
    if (movieId) refreshVocabStatus();
  } else if (movieId && vocabActive() && vocabView.status.state !== 'handing-off') {
    refreshVocabStatus();
  }
  renderOrganizeVocab();
}

function renderOrganizeVocab() {
  const button = $('organizeVocab');
  const hint = $('organizeVocabHint');
  const st = view.status;
  const tracks = st && st.onWatchPage && Array.isArray(st.tracks) ? st.tracks : [];
  const active = tracks.find((t) => t.id === st.activeTrackId);
  // Gated on the track's language tag (primary subtag), same check as content.js.
  const english = !!active && MS.normalizeBcp47(active.language) === 'en';
  // Pressing it again while this episode is being organized changes nothing.
  button.disabled = !english || vocabActive();
  const reason = '生詞本只支援英文字幕';
  // Only touch the hint for this reason, never a click-triggered error.
  if (!english && tracks.length) {
    hint.textContent = reason;
    hint.className = 'hint';
  } else if (english && hint.textContent === reason) {
    hint.textContent = '';
  }
  renderVocabStatus();
}

function vocabStatusLines(status) {
  const wait = '約需幾分鐘，可以繼續看片';
  switch (status.state) {
    case 'handing-off':
      return { text: '正在交給 MultiSub App…', busy: true };
    case 'queued':
      return { text: '已交給 MultiSub App，稍後開始整理', sub: wait, busy: true };
    case 'running': {
      // done stays 0 while the engine starts (a local model can take a
      // while to load); 0/N would look stuck.
      if (!(status.done > 0)) return { text: '準備中…', sub: wait, busy: true };
      const count = status.total > 0 ? '（' + status.done + '/' + status.total + '）' : '…';
      return { text: '整理中' + count, sub: wait, busy: true };
    }
    case 'done':
      // 打開生詞本 sits right under it, so no line saying where to look.
      return { text: '整理好了：' + (status.wordCount || 0) + ' 個單字', cls: 'ok', open: true };
    case 'failed':
      return { text: organizeVocabErrorText(status.code, status.message), cls: 'err' };
    default:
      return null;
  }
}

function renderVocabStatus() {
  const lines = vocabView.status ? vocabStatusLines(vocabView.status) : null;
  $('vocabStatus').hidden = !lines;
  if (!lines) return;
  $('vocabSpinner').hidden = !lines.busy;
  const text = $('vocabStatusText');
  text.textContent = lines.text;
  text.className = 'vocab-status-text' + (lines.cls ? ' ' + lines.cls : '');
  const sub = $('vocabStatusSub');
  // 打開生詞本 may leave the app behind Safari too; its result replaces the
  // line saying where to look, until the status changes.
  const note = lines.open && vocabView.openNote;
  sub.textContent = note || lines.sub || '';
  sub.className = 'vocab-status-sub' + (note && vocabView.openNoteErr ? ' err' : '');
  $('openVocab').hidden = !lines.open;
}

async function refreshVocabStatus() {
  const movieId = vocabView.movieId;
  if (!movieId || vocabView.inFlight) return;
  vocabView.inFlight = true;
  let res;
  try {
    res = await send({ type: 'vocab-status', movieId: movieId });
  } finally {
    vocabView.inFlight = false;
  }
  // Another episode by now, or a click went out while this was asked.
  if (movieId !== vocabView.movieId || (vocabView.status && vocabView.status.state === 'handing-off')) return;
  // Unreachable: keep what's shown, the next poll asks again.
  if (!res || !res.ok) return;
  const next = res.state === 'none' ? null : res;
  if (!next || !vocabView.status || next.state !== vocabView.status.state) {
    vocabView.openNote = '';
    vocabView.openNoteErr = false;
  }
  vocabView.status = next;
  renderOrganizeVocab();
}

function organizeVocabErrorText(code, detail) {
  const again = '再整理一次';
  switch (code) {
    case 'non-english': return '生詞本只支援英文字幕';
    case 'no-episode': return '等字幕載入後再試一次';
    case 'open-failed': return '打不開 MultiSub App，請確認已安裝';
    case 'tab-unreachable': return '連不到 Netflix 分頁';
    case 'native-unavailable': return MS.errorText(code);
    // From the app's status (see VocabExtractionManager).
    case 'engine-not-ready': return '還沒設定 AI 引擎。在 MultiSub App 設定好後' + again;
    case 'model-not-ready': return '本機模型還沒下載。在 App 下載或改用 API Key 後' + again;
    case 'auth-failed':
    case 'rate-limited':
    case 'network':
    case 'provider-error':
      return '整理失敗：' + MS.errorText(code);
    case 'vocab-empty': return '沒整理出單字，可能是 AI 服務連不上，稍後' + again;
    case 'vocab-interrupted': return '整理到一半停了，可能是 App 被關掉，' + again + '就好';
    case 'vocab-not-started': return 'App 沒有開始整理。打開 MultiSub App 後' + again;
    default: return detail || '整理失敗，請再試一次（' + (code || 'unknown') + '）';
  }
}

async function onOrganizeVocab() {
  const hint = $('organizeVocabHint');
  hint.textContent = '';
  hint.className = 'hint';
  if (!view.tab) return;
  vocabView.status = { state: 'handing-off' };
  vocabView.openNote = '';
  renderOrganizeVocab();
  let res;
  try {
    res = await api.tabs.sendMessage(view.tab.id, { type: 'organize-vocab' });
  } catch (e) {
    res = { ok: false, error: 'tab-unreachable' };
  }
  if (!res || !res.ok) {
    vocabView.status = null;
    hint.textContent = organizeVocabErrorText(res && res.error);
    hint.className = 'hint err';
    renderOrganizeVocab();
    return;
  }
  // Shown until the app's own status comes back, right below.
  vocabView.status = { state: 'queued' };
  renderOrganizeVocab();
  refreshVocabStatus();
}

async function onOpenVocab() {
  const res = await send({ type: 'open-app', destination: 'vocab' });
  vocabView.openNoteErr = !res || !res.ok;
  vocabView.openNote = vocabView.openNoteErr
    ? '打不開 MultiSub App，請確認已安裝'
    : '沒看到的話，請切到 MultiSub App 的「生詞本」';
  renderVocabStatus();
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

  $('engineChange').addEventListener('click', openEngineSetup);
  $('engineOpenApp').addEventListener('click', openEngineSetup);

  $('fontScale').addEventListener('input', (e) => {
    settings = Object.assign({}, settings, { fontScale: parseFloat(e.target.value) });
    $('fontScaleValue').textContent = Math.round(settings.fontScale * 100) + '%';
    previewDisplay();
    saveSettingsSoon();
  });
  $('bottomOffset').addEventListener('input', (e) => {
    settings = Object.assign({}, settings, { bottomOffset: parseInt(e.target.value, 10) });
    $('bottomOffsetValue').textContent = settings.bottomOffset + '%';
    previewDisplay();
    saveSettingsSoon();
  });
  // Let go of a slider: store it now, before Safari may close the popup.
  for (const id of ['fontScale', 'bottomOffset']) {
    $(id).addEventListener('change', () => {
      clearTimeout(saveTimer);
      saveSettingsNow();
    });
  }
  $('displaySettings').addEventListener('toggle', () => {
    revealDisplaySettings();
    updateMoreBelow();
  });
  window.addEventListener('scroll', updateMoreBelow, { passive: true });
  window.addEventListener('resize', updateMoreBelow);
  // Anything that changes the page's height (a status line wrapping, a
  // banner, the vocabulary status) can change whether there is more below.
  if (typeof ResizeObserver === 'function') new ResizeObserver(updateMoreBelow).observe(document.body);
  $('mergedMode').addEventListener('change', (e) => {
    settings = Object.assign({}, settings, { mergedMode: e.target.checked });
    saveSettingsNow();
  });
  $('dragMode').addEventListener('change', (e) => setDragMode(e.target.checked));
  $('sourceTrack').addEventListener('change', onTrackPicked);
  $('openStyles').addEventListener('click', onOpenStyles);
  $('organizeVocab').addEventListener('click', onOrganizeVocab);
  $('openVocab').addEventListener('click', onOpenVocab);
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
  // Wait for the first ping (and the tab check) behind a neutral loading
  // line, so a mode or language chosen in the app is adopted before the
  // switch shows the default, and the engine card and status line don't
  // show a state that's about to change.
  await Promise.race([Promise.all([refreshNative(), refreshTab()]), sleep(FIRST_PING_WAIT_MS)]);
  render();
  document.body.classList.remove('loading');
  setInterval(refreshTab, STATUS_POLL_MS);
  setInterval(refreshNative, NATIVE_POLL_MS);
}

init();

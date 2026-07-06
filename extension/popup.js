'use strict';

const api = typeof browser !== 'undefined' ? browser : chrome;

// D1: kept in sync with SubtitleStyle in TranslatorCore.swift / content.js's
// own copy. popup.js has no style controls itself — it only relays whatever
// the native `ping` response carries into storage.local (see refreshNativeStatus).
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
  bottomOffset: 10,
  styles: DEFAULT_STYLES,
  mergedMode: false
};

let settings = Object.assign({}, DEFAULT_SETTINGS);

const el = (id) => document.getElementById(id);

const AUTO_TRACK_VALUE = '__auto__';

function renderSettings() {
  el('enabled').checked = settings.enabled;
  el('targetLang').value = settings.targetLang;
  el('fontScale').value = settings.fontScale;
  el('bottomOffset').value = settings.bottomOffset;
  el('fontScaleValue').textContent = Math.round(settings.fontScale * 100) + '%';
  el('bottomOffsetValue').textContent = settings.bottomOffset + '%';
  el('mergedMode').checked = !!settings.mergedMode;
}

let saveTimer = null;
function saveSettings() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    api.storage.local.set({ settings: settings });
  }, 150);
}

function bindInputs() {
  el('enabled').addEventListener('change', (e) => {
    settings.enabled = e.target.checked;
    saveSettings();
  });
  el('targetLang').addEventListener('change', (e) => {
    settings.targetLang = e.target.value;
    saveSettings();
  });
  el('fontScale').addEventListener('input', (e) => {
    settings.fontScale = parseFloat(e.target.value);
    el('fontScaleValue').textContent = Math.round(settings.fontScale * 100) + '%';
    saveSettings();
  });
  el('bottomOffset').addEventListener('input', (e) => {
    settings.bottomOffset = parseInt(e.target.value, 10);
    el('bottomOffsetValue').textContent = settings.bottomOffset + '%';
    saveSettings();
  });
  el('dragMode').addEventListener('change', (e) => {
    setDragMode(e.target.checked);
  });
  el('mergedMode').addEventListener('change', (e) => {
    settings.mergedMode = e.target.checked;
    saveSettings();
  });
  el('openStyles').addEventListener('click', openStyles);
  el('organizeVocab').addEventListener('click', organizeVocab);
}

// D2: not a `settings` field (see PLAN.md D2 — deliberately not persisted to
// storage.local so it can't linger enabled across reloads). Sent straight to
// the active tab's content.js, which is the only place that tracks it.
async function setDragMode(enabled) {
  const tab = await activeTab();
  if (!tab) return;
  try {
    await api.tabs.sendMessage(tab.id, { type: 'set-drag-mode', enabled: enabled });
  } catch (e) { /* tab gone */ }
}

async function openStyles() {
  const hint = el('openStylesHint');
  hint.textContent = '';
  hint.className = '';
  try {
    const res = await api.runtime.sendMessage({ type: 'open-app' });
    if (!res || !res.ok) {
      hint.textContent = 'MultiSub App 未安裝或無法開啟（' + (res && res.error || 'unknown') + '）';
      hint.className = 'err';
    }
  } catch (e) {
    hint.textContent = '無法連到 MultiSub App，請確認已安裝於 /Applications';
    hint.className = 'err';
  }
}

// D1: merges a `styles` object from a native `ping` response into
// storage.local.settings if it differs — content.js's storage.onChanged
// listener on the Netflix tab then applies it to the overlay.
function mergeStylesFromNative(res) {
  if (!res || !res.ok || !res.styles) return;
  if (JSON.stringify(res.styles) === JSON.stringify(settings.styles)) return;
  settings = Object.assign({}, settings, { styles: res.styles });
  api.storage.local.set({ settings: settings });
}

async function activeTab() {
  const tabs = await api.tabs.query({ active: true, currentWindow: true });
  return tabs[0] || null;
}

const STATUS_TEXT = {
  'idle': '不在播放頁',
  'waiting-tracks': '等待字幕資料…',
  'fetching': '下載字幕中…',
  'translating': '翻譯中',
  'done': '翻譯完成 ✓',
  'fallback': '即時翻譯模式（逐句）',
  'error': '發生錯誤'
};

async function refreshEpisodeStatus() {
  const tab = await activeTab();
  if (!tab) return;
  let status = null;
  try {
    status = await api.tabs.sendMessage(tab.id, { type: 'get-status' });
  } catch (e) {
    el('episodeStatus').textContent = '請在 Netflix 分頁開啟本視窗';
    el('organizeVocab').disabled = true;
    return;
  }
  if (!status || !status.onWatchPage) {
    el('episodeStatus').textContent = '不在 Netflix 播放頁';
    el('organizeVocab').disabled = true;
    return;
  }
  let text = STATUS_TEXT[status.status] || status.status;
  if (status.status === 'translating' && status.totalCues) {
    text += '：' + status.translatedCount + ' / ' + status.totalCues + ' 句';
  }
  if (status.errorHint) text = status.errorHint;
  el('episodeStatus').textContent = text;

  // D2: content.js is the source of truth for drag mode (not storage.local),
  // so sync the checkbox from get-status rather than settings.
  el('dragMode').checked = !!status.dragMode;

  // Source track picker (first option is always "auto = follow Netflix")
  if (status.tracks && status.tracks.length) {
    const section = el('trackSection');
    section.hidden = false;
    const select = el('sourceTrack');
    if (select.options.length !== status.tracks.length + 1) {
      select.innerHTML = '';
      const autoOpt = document.createElement('option');
      autoOpt.value = AUTO_TRACK_VALUE;
      autoOpt.textContent = '自動（跟隨 Netflix）';
      select.appendChild(autoOpt);
      for (const t of status.tracks) {
        const opt = document.createElement('option');
        opt.value = t.id;
        opt.textContent = t.label + (t.forced ? '（強制）' : '') +
          (/closed/i.test(t.trackType) ? '（CC）' : '');
        select.appendChild(opt);
      }
      select.onchange = async () => {
        try {
          if (select.value === AUTO_TRACK_VALUE) {
            await api.tabs.sendMessage(tab.id, { type: 'set-track-auto' });
          } else {
            await api.tabs.sendMessage(tab.id, { type: 'set-track', trackId: select.value });
          }
        } catch (e) { /* tab gone */ }
      };
    }
    select.value = status.sourceMode === 'manual' && status.activeTrackId
      ? status.activeTrackId : AUTO_TRACK_VALUE;
  }

  updateOrganizeVocabButton(status);
}

// V4: bcp47-based gate (vocab-design.md §4) — checks the primary subtag only,
// not any text-content language detection. Mirrors content.js's
// normalizeBcp47 for the one comparison this popup needs.
function isEnglishBcp47(code) {
  return !!code && String(code).toLowerCase().split('-')[0] === 'en';
}

// Enables/disables "整理本集單字" based on the current source track's
// language, using the same tracks/activeTrackId data get-status already
// returns for the track picker above — no extra protocol needed.
function updateOrganizeVocabButton(status) {
  const button = el('organizeVocab');
  const hint = el('organizeVocabHint');
  const activeTrack = (status.tracks || []).find((t) => t.id === status.activeTrackId);
  const sourceLang = activeTrack ? activeTrack.language : '';
  const enabled = !!(status.tracks && status.tracks.length) && isEnglishBcp47(sourceLang);
  button.disabled = !enabled;
  // Only touch the hint for this specific reason — don't clobber a
  // click-triggered error hint (e.g. "App 未安裝") that might be showing.
  if (!enabled && status.tracks && status.tracks.length) {
    hint.textContent = '生詞本僅支援英文字幕';
    hint.className = '';
  } else if (enabled && hint.textContent === '生詞本僅支援英文字幕') {
    hint.textContent = '';
  }
}

async function organizeVocab() {
  const hint = el('organizeVocabHint');
  hint.textContent = '';
  hint.className = '';
  const tab = await activeTab();
  if (!tab) return;
  try {
    const res = await api.tabs.sendMessage(tab.id, { type: 'organize-vocab' });
    if (!res || !res.ok) {
      hint.textContent = organizeVocabErrorText(res && res.error);
      hint.className = 'err';
    }
  } catch (e) {
    hint.textContent = '無法連到 Netflix 分頁';
    hint.className = 'err';
  }
}

function organizeVocabErrorText(code) {
  switch (code) {
    case 'non-english': return '生詞本僅支援英文字幕';
    case 'no-episode': return '請等字幕載入後再試一次';
    case 'open-failed': return 'MultiSub App 未安裝或無法開啟';
    case 'bad-request': return '整理失敗，請重試';
    default: return '整理失敗（' + (code || 'unknown') + '）';
  }
}

async function refreshNativeStatus() {
  const node = el('nativeStatus');
  try {
    const res = await api.runtime.sendMessage({ type: 'ping-native' });
    mergeStylesFromNative(res);
    if (res && res.ok) {
      if (res.modelLoaded) {
        node.textContent = '模型已就緒：' + (res.modelId || '');
        node.className = 'ok';
      } else if (res.modelDownloaded) {
        node.textContent = '模型已下載（首句翻譯時載入）';
        node.className = 'ok';
      } else {
        node.textContent = '模型尚未下載，請開啟 MultiSub App';
        node.className = 'err';
      }
    } else {
      node.textContent = '無法連到 MultiSub App（' + (res && res.error || 'unknown') + '）';
      node.className = 'err';
    }
  } catch (e) {
    node.textContent = '無法連到 MultiSub App';
    node.className = 'err';
  }
}

// D2: bidirectional slider sync — a drag on the Netflix overlay writes
// settings.bottomOffset straight to storage.local (see content.js's
// onDragPointerUp), so the popup needs to notice that change and re-render
// while it's open, mirroring the sync content.js already does for itself.
api.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.settings) return;
  settings = Object.assign({}, DEFAULT_SETTINGS, changes.settings.newValue || {});
  renderSettings();
});

async function init() {
  const res = await api.storage.local.get('settings');
  if (res && res.settings) settings = Object.assign({}, DEFAULT_SETTINGS, res.settings);
  renderSettings();
  bindInputs();
  refreshEpisodeStatus();
  refreshNativeStatus();
  setInterval(refreshEpisodeStatus, 2000);
  // D1: piggyback style sync on the same 2s cadence so App-side edits reach
  // the Netflix overlay quickly while the popup is open (see PLAN.md D1).
  // Also piggybacks the D4 cache index sync (see background.js's pingNative).
  setInterval(refreshNativeStatus, 2000);
}

init();

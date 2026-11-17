// Scenario from ?s=: netflix | chooser | translate | setup | annotate | netflix-none | perm | reload
(function () {
  const s = new URLSearchParams(location.search).get('s') || 'translate';
  const ev = () => ({ addListener() {} });
  const engineCloud = { configured: 'auto', active: 'cloud', provider: 'anthropic', providerName: 'Anthropic Claude', model: 'claude-haiku-5-5', hasKey: true };
  const engineNone = { configured: 'auto', active: null, provider: 'anthropic', providerName: 'Anthropic Claude', model: 'claude-haiku-5-5', hasKey: false };
  const mode = { netflix: 'netflix', chooser: null, translate: 'translate', setup: 'translate', annotate: 'annotate', 'netflix-none': 'netflix', perm: 'translate', reload: 'netflix' }[s];
  let stored = mode ? { enabled: true, mode, targetLang: 'zh-TW', annotateLevel: 'B1', fontScale: 1, bottomOffset: 10, mergedMode: true, prefsUpdatedAt: 5 } : undefined;
  const tracks = [{ id: 'en', language: 'en', label: 'English', forced: false, trackType: 'SUBTITLES' }, { id: 'zh', language: 'zh-Hant', label: '中文（繁體）', forced: false, trackType: 'SUBTITLES' }];
  const status = {
    netflix: { onWatchPage: true, status: 'ready', secondState: 'ready', secondaryTrackFound: true, tracks, activeTrackId: 'en', sourceMode: 'auto', totalCues: 860 },
    translate: { onWatchPage: true, status: 'translating', translatedCount: 120, totalCues: 860, tracks, activeTrackId: 'en', sourceMode: 'auto', jobKind: 'translate' },
    setup: { onWatchPage: true, status: 'error', errorCode: 'engine-not-ready', tracks, activeTrackId: 'en', totalCues: 860, translatedCount: 0 },
    annotate: { onWatchPage: true, status: 'done', jobKind: 'annotate', tracks, activeTrackId: 'en', totalCues: 860, translatedCount: 860 },
    'netflix-none': { onWatchPage: true, status: 'ready', secondState: 'none', secondaryTrackFound: false, tracks, activeTrackId: 'en' },
    perm: null, reload: null, chooser: { onWatchPage: true, status: 'no-mode', tracks }
  }[s];
  const providers = [
    { id: 'anthropic', name: 'Anthropic Claude', defaultModel: 'claude-haiku-5-5', keyPlaceholder: 'sk-ant-…', keyURL: 'https://console.anthropic.com/settings/keys', needsBaseURL: false,
      recommended: [{ id: 'claude-haiku-5-5', label: '最快（推薦）' }, { id: 'claude-sonnet-5-5', label: '平衡' }, { id: 'claude-opus-5-5', label: '最高品質' }] },
    { id: 'openai', name: 'OpenAI', defaultModel: 'gpt-6-luna', keyPlaceholder: 'sk-…', keyURL: 'https://platform.openai.com/api-keys', needsBaseURL: false,
      recommended: [{ id: 'gpt-6-luna', label: '最快（推薦）' }] },
    { id: 'custom', name: '自訂（OpenAI 相容）', defaultModel: '', keyPlaceholder: '選填', keyURL: '', needsBaseURL: true, recommended: [] }
  ];
  let saved = false;
  window.browser = {
    runtime: {
      onMessage: ev(),
      async sendMessage(m) {
        if (m.type === 'ping-native') { await new Promise((r) => setTimeout(r, 400)); return { ok: true, engine: (!saved && (s === 'setup' || s === 'chooser')) ? engineNone : engineCloud, prefs: { updatedAt: 0 } }; }
        if (m.type === 'get-engine-options') return { ok: true, providers, engine: engineNone };
        if (m.type === 'set-engine') { saved = true; return { ok: true, engine: engineCloud }; }
        if (m.type === 'test-engine') return { ok: true, latencyMs: 912 };
        return { ok: true };
      }
    },
    storage: { onChanged: ev(), local: { async get() { return stored ? { settings: stored } : {}; }, async set(o) { stored = o.settings; } } },
    tabs: {
      async query() { return [{ id: 1, url: s === 'perm' ? undefined : 'https://www.netflix.com/watch/81' }]; },
      async sendMessage(id, m) { if (m.type === 'get-status') { if (!status) throw new Error('no receiver'); return status; } return { ok: true }; },
      async reload() {}, async create() {}
    },
    permissions: { async contains() { return s !== 'perm'; }, async request() { return true; } }
  };
})();

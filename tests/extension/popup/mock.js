// Scripted `browser` for popup.js. Scenario config comes from the URL hash.
(function () {
  const cfg = JSON.parse(decodeURIComponent(location.hash.slice(1) || '%7B%7D'));
  window.__cfg = cfg;
  // The system's preferred languages, as shared.js reads them for the
  // default second language (headless Chrome's own would vary by machine).
  if (cfg.languages) {
    Object.defineProperty(navigator, 'languages', { get: () => cfg.languages.slice() });
    Object.defineProperty(navigator, 'language', { get: () => cfg.languages[0] });
  }
  window.__log = [];
  const store = JSON.parse(JSON.stringify(cfg.store || {}));
  window.__store = store;
  const ev = () => ({ addListener() {} });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const copy = (x) => JSON.parse(JSON.stringify(x));
  const cloud = { configured: 'cloud', active: 'cloud', provider: 'openai', providerName: 'OpenAI', model: 'gpt-6-luna', hasKey: true };
  // cfg.consentedBaseURLs: the custom addresses native has consent for
  // (normalized the way native does), which get-engine-options reports and
  // set-engine enforces per address, like the native side.
  const consented = Array.isArray(cfg.consentedBaseURLs) ? cfg.consentedBaseURLs.slice() : null;
  const normalize = (raw) => {
    try { const u = new URL(String(raw || '').trim()); return u.protocol + '//' + u.host + u.pathname.replace(/\/+$/, ''); } catch (e) { return null; }
  };
  function engineOptions() {
    const providers = copy(cfg.providers || []);
    if (consented) for (const p of providers) if (p.id === 'custom') p.consentedBaseURLs = consented.slice();
    return { ok: true, providers, engine: cfg.engine };
  }
  // vocab-status: cfg.vocabInitial until 整理本集單字 is pressed, then the
  // replies in cfg.vocabAfter one per call (the last one repeats).
  let organized = false;
  let vocabCalls = 0;
  function vocabStatus() {
    if (!organized) return cfg.vocabInitial || { ok: true, state: 'none' };
    const seq = cfg.vocabAfter || [{ ok: true, state: 'none' }];
    return seq[Math.min(vocabCalls++, seq.length - 1)];
  }
  window.browser = {
    runtime: {
      onMessage: ev(),
      async sendMessage(m) {
        window.__log.push(copy(m));
        const r = (cfg.replies || {})[m.type];
        if (m.type === 'ping-native') { await sleep(cfg.pingDelay || 0); return { ok: true, engine: cfg.engine, prefs: cfg.prefs || { updatedAt: 0 } }; }
        if (m.type === 'get-engine-options') return engineOptions();
        if (m.type === 'test-engine') { await sleep(20); return r || { ok: true, latencyMs: 912, sample: '你好' }; }
        if (m.type === 'set-engine') {
          if (m.engine === 'cloud' && cfg.requireConsent && !m.consent) return { ok: false, error: 'consent-required' };
          if (m.engine === 'cloud' && m.provider === 'custom' && consented) {
            const url = normalize(m.baseURL);
            if (m.consent) { if (!consented.includes(url)) consented.push(url); }
            else if (!consented.includes(url)) return { ok: false, error: 'consent-required' };
          }
          return r || { ok: true, engine: m.engine === 'local' ? Object.assign({}, cfg.engine, { configured: 'local', active: 'local' }) : cloud };
        }
        if (m.type === 'list-models') return r || { ok: true, models: ['gpt-x', 'gpt-y'] };
        if (m.type === 'vocab-status') { await sleep(10); return copy(Object.assign({ movieId: m.movieId }, vocabStatus())); }
        if (m.type === 'open-app') return r || { ok: true };
        return { ok: true };
      }
    },
    storage: {
      onChanged: ev(),
      local: {
        async get(k) { const out = {}; for (const key of [].concat(k)) if (key in store) out[key] = copy(store[key]); return out; },
        async set(o) { Object.assign(store, copy(o)); window.__log.push({ type: 'storage.set', keys: Object.keys(o) }); },
        async remove(k) { for (const key of [].concat(k)) delete store[key]; window.__log.push({ type: 'storage.remove', keys: [].concat(k) }); }
      }
    },
    tabs: {
      async query() { return [{ id: 1, url: cfg.tabUrl }]; },
      async sendMessage(id, m) {
        if (m.type === 'get-status') { if (!cfg.status) throw new Error('no receiver'); return cfg.status; }
        if (m.type === 'organize-vocab') {
          window.__log.push({ type: 'tab:organize-vocab' });
          await sleep(30);
          if (cfg.organizeThrows) throw new Error('no receiver');
          organized = true;
          return cfg.organizeReply || { ok: true };
        }
        return { ok: true };
      },
      async reload() {},
      async create(o) { window.__log.push({ type: 'tabs.create', url: o.url, draftAtCreate: copy(store.engineDraft || null) }); }
    },
    permissions: { async contains() { return cfg.permission !== false; }, async request() { return true; } }
  };
})();

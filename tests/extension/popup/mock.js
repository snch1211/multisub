// Scripted `browser` for popup.js. Scenario config comes from the URL hash.
(function () {
  const cfg = JSON.parse(decodeURIComponent(location.hash.slice(1) || '%7B%7D'));
  window.__cfg = cfg;
  window.__log = [];
  const store = JSON.parse(JSON.stringify(cfg.store || {}));
  window.__store = store;
  const ev = () => ({ addListener() {} });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const copy = (x) => JSON.parse(JSON.stringify(x));
  const cloud = { configured: 'cloud', active: 'cloud', provider: 'openai', providerName: 'OpenAI', model: 'gpt-6-luna', hasKey: true };
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
        if (m.type === 'ping-native') { await sleep(cfg.pingDelay || 0); return { ok: true, engine: cfg.engine, prefs: { updatedAt: 0 } }; }
        if (m.type === 'get-engine-options') return { ok: true, providers: cfg.providers, engine: cfg.engine };
        if (m.type === 'test-engine') { await sleep(20); return r || { ok: true, latencyMs: 912, sample: '你好' }; }
        if (m.type === 'set-engine') {
          if (m.engine === 'cloud' && cfg.requireConsent && !m.consent) return { ok: false, error: 'consent-required' };
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

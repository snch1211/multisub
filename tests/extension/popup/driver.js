// Runs one scenario against the real popup and writes the results into #__out.
(function () {
  const cfg = window.__cfg;
  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  async function waitFor(fn, ms = 4000) {
    const end = Date.now() + ms;
    while (Date.now() < end) { try { if (fn()) return true; } catch (e) { /* not yet */ } await sleep(25); }
    throw new Error('timed out: ' + fn.toString().slice(0, 120));
  }
  const fire = (el, type) => el.dispatchEvent(new Event(type, { bubbles: true }));
  const type = (id, v) => { $(id).value = v; fire($(id), 'input'); };
  const choose = (id, v) => { $(id).value = v; fire($(id), 'change'); };
  const visible = (id) => { const el = $(id); return !!el && !el.closest('[hidden]'); };
  const QUIET = ['ping-native', 'get-engine-options', 'storage.set', 'storage.remove', 'set-prefs'];
  const log = () => window.__log.filter((m) => !QUIET.includes(m.type));
  // Every distinct state of the 整理本集單字 status block, in order.
  function watchVocab() {
    const seen = [];
    let stop = false;
    const snap = () => ({ shown: visible('vocabStatus'), text: $('vocabStatusText').textContent, sub: $('vocabStatusSub').textContent,
      cls: $('vocabStatusText').className, spinner: visible('vocabSpinner'), open: visible('openVocab'), disabled: $('organizeVocab').disabled });
    (async () => {
      while (!stop) {
        const s = snap();
        const last = seen[seen.length - 1];
        if (!last || JSON.stringify(last) !== JSON.stringify(s)) seen.push(s);
        await sleep(20);
      }
    })();
    return { seen, stop: () => { stop = true; } };
  }
  const vocabCalls = () => window.__log.filter((m) => m.type === 'vocab-status');
  const S = {
    async 'vocab-handoff'() {
      await waitFor(() => !document.body.classList.contains('loading') && !$('organizeVocab').disabled);
      const before = { shown: visible('vocabStatus'), calls: vocabCalls().length };
      const w = watchVocab();
      $('organizeVocab').click();
      await waitFor(() => /整理好了/.test($('vocabStatusText').textContent), 12000);
      const callsAtDone = vocabCalls().length;
      await sleep(4500); // two more tab polls: done is final, nothing more is asked
      w.stop();
      $('openVocab').click();
      await waitFor(() => /沒看到|打不開/.test($('vocabStatusSub').textContent));
      return { before, seen: w.seen, callsAtDone, callsAfter: vocabCalls().length, movieIds: vocabCalls().map((m) => m.movieId),
        organizeSent: window.__log.filter((m) => m.type === 'tab:organize-vocab').length,
        openApp: window.__log.filter((m) => m.type === 'open-app'), sub: $('vocabStatusSub').textContent, subCls: $('vocabStatusSub').className };
    },
    async 'vocab-on-open'() {
      await waitFor(() => !document.body.classList.contains('loading'));
      await waitFor(() => vocabCalls().length > 0);
      await sleep(100);
      const first = { shown: visible('vocabStatus'), text: $('vocabStatusText').textContent, sub: $('vocabStatusSub').textContent,
        cls: $('vocabStatusText').className, open: visible('openVocab'), spinner: visible('vocabSpinner'), disabled: $('organizeVocab').disabled };
      await sleep(4500);
      return { first, calls: vocabCalls().length };
    },
    async 'vocab-click-error'() {
      await waitFor(() => !document.body.classList.contains('loading') && !$('organizeVocab').disabled);
      $('organizeVocab').click();
      await waitFor(() => $('organizeVocabHint').textContent);
      await sleep(100);
      return { hint: $('organizeVocabHint').textContent, cls: $('organizeVocabHint').className, shown: visible('vocabStatus'),
        disabled: $('organizeVocab').disabled, calls: vocabCalls().length };
    },
    async 'list-models'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'openai');
      type('apiKey', 'sk-typed');
      $('loadModels').click();
      await waitFor(() => /找到/.test($('engineResult').textContent));
      return { sent: log(), keyField: $('apiKey').value, result: $('engineResult').textContent,
        options: Array.from($('model').options).map((o) => o.value) };
    },
    async 'list-models-nokey'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'openai');
      $('loadModels').click();
      await sleep(100);
      return { sent: log(), result: $('engineResult').textContent };
    },
    async 'save-consent'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'openai');
      type('apiKey', 'sk-typed');
      $('engineForm').requestSubmit();
      await waitFor(() => visible('consentStep'));
      const step = { title: $('consentTitle').textContent, text: $('consentText').textContent,
        saveHidden: !visible('saveEngine'), sentBefore: log() };
      $('consentAccept').click();
      await waitFor(() => visible('engineSummary'));
      return { step, sent: log(), notice: $('engineNotice').textContent, summary: $('engineSummaryText').textContent,
        keyField: $('apiKey').value, draftRemoved: window.__log.some((m) => m.type === 'storage.remove' && m.keys.includes('engineDraft')) };
    },
    async 'save-consent-cancel'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'custom');
      type('baseURL', 'http://localhost:1234/v1');
      type('modelCustom', 'qwen3');
      $('engineForm').requestSubmit();
      await waitFor(() => visible('consentStep'));
      const text = $('consentText').textContent;
      $('consentCancel').click();
      await sleep(50);
      return { text, sent: log(), stepHidden: !visible('consentStep'), result: $('engineResult').textContent, formShown: visible('engineForm') };
    },
    // Custom endpoint: agreed to A before. B brings up the step naming B
    // (取消); back to A saves with no step.
    async 'custom-url-consent'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'custom');
      type('baseURL', cfg.urlB);
      type('modelCustom', 'qwen3');
      $('engineForm').requestSubmit();
      await waitFor(() => visible('consentStep'));
      const toB = { text: $('consentText').textContent, sent: log() };
      $('consentCancel').click();
      await sleep(50);
      const mark = log().length;
      type('baseURL', cfg.urlA);
      $('engineForm').requestSubmit();
      await waitFor(() => visible('engineSummary') || visible('consentStep'));
      const backToA = { stepShown: visible('consentStep'), sent: log().slice(mark) };
      return { toB, backToA };
    },
    async 'save-test-fails'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'openai');
      type('apiKey', 'sk-bad');
      $('engineForm').requestSubmit();
      await waitFor(() => $('engineResult').textContent && !/測試中/.test($('saveEngine').textContent));
      return { sent: log(), result: $('engineResult').textContent, cls: $('engineResult').className };
    },
    async 'save-nokey'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'openai');
      $('engineForm').requestSubmit();
      await sleep(80);
      return { sent: log(), result: $('engineResult').textContent };
    },
    async 'save-known-consent'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'openai');
      type('apiKey', 'sk-typed');
      $('engineForm').requestSubmit();
      await waitFor(() => visible('engineSummary') || visible('consentStep'));
      return { sent: log(), stepShown: visible('consentStep') };
    },
    async 'draft-keylink'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      choose('provider', 'openai');
      choose('model', 'gpt-6-luna');
      type('apiKey', 'sk-never-stored');
      $('keyLink').click();
      await waitFor(() => window.__log.some((m) => m.type === 'tabs.create'));
      return { create: window.__log.find((m) => m.type === 'tabs.create'), stored: window.__store.engineDraft };
    },
    async 'draft-restore'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      return { provider: $('provider').value, model: $('model').value, formShown: visible('engineForm'), summaryShown: visible('engineSummary') };
    },
    async 'perm'() {
      await waitFor(() => !document.body.classList.contains('loading'));
      await sleep(100);
      return { banner: visible('banner') && $('bannerText').textContent, action: $('bannerAction').textContent,
        status: $('statusText').textContent, openNetflixShown: visible('openNetflix') };
    },
    async 'local-downloaded'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      const label = $('useLocal').textContent;
      $('useLocal').click();
      await waitFor(() => visible('engineSummary'));
      return { label, sent: log(), notice: $('engineNotice').textContent, summary: $('engineSummaryText').textContent };
    },
    async 'local-missing'() {
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      const label = $('useLocal').textContent;
      $('useLocal').click();
      await sleep(80);
      return { label, sent: log(), result: $('engineResult').textContent };
    },
    async 'local-active'() {
      await waitFor(() => visible('engineSummary'));
      $('engineChange').click();
      await waitFor(() => visible('engineForm') && $('provider').options.length);
      return { useLocalShown: visible('useLocal'), cancelShown: visible('engineCancel') };
    },
    async 'slow-ping'() {
      const snaps = [];
      await sleep(1000);
      snaps.push({ at: 1000, loading: document.body.classList.contains('loading'), chooserShown: visible('chooser') });
      await waitFor(() => !document.body.classList.contains('loading'), 6000);
      await sleep(10);
      snaps.push({ at: 'after', chooserShown: visible('chooser'), mainShown: visible('main'), engineNotice: $('engineNotice').textContent, engineCard: visible('engineCard') });
      return { snaps };
    },
    async 'defaults'() {
      await waitFor(() => !document.body.classList.contains('loading'), 6000);
      await sleep(100);
      const checked = Array.from($('modeSwitch').querySelectorAll('[aria-checked="true"]')).map((b) => b.dataset.mode);
      return { checked, targetLang: $('targetLang').value, modeDesc: $('modeDesc').textContent,
        mainShown: visible('main'), engineCard: visible('engineCard'), displaySettings: visible('displaySettings'),
        vocabShown: visible('vocabSection'), chooser: !!document.getElementById('chooser'),
        sentPrefs: window.__log.filter((m) => m.type === 'set-prefs'), stored: window.__store.settings || null };
    },
    async 'display-change'() {
      await waitFor(() => !document.body.classList.contains('loading'), 6000);
      $('mergedMode').checked = false;
      fire($('mergedMode'), 'change');
      await sleep(100);
      return { stored: window.__store.settings || null, sentPrefs: window.__log.filter((m) => m.type === 'set-prefs') };
    },
    async 'pick-mode'() {
      await waitFor(() => !document.body.classList.contains('loading'), 6000);
      $('modeSwitch').querySelector('[data-mode="translate"]').click();
      await sleep(100);
      return { sentPrefs: window.__log.filter((m) => m.type === 'set-prefs'), stored: window.__store.settings,
        engineCard: visible('engineCard') };
    }
  };
  (async () => {
    let out;
    try { out = { ok: true, result: await S[cfg.scenario]() }; }
    catch (e) { out = { ok: false, error: String(e && e.message || e), log: window.__log }; }
    const pre = document.createElement('pre');
    pre.id = '__out';
    pre.textContent = '@@OUT@@' + JSON.stringify(out) + '@@END@@';
    document.body.appendChild(pre);
  })();
})();

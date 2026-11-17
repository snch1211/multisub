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
    async 'engine-card'() {
      await waitFor(() => !document.body.classList.contains('loading'), 6000);
      await sleep(100);
      const card = { summaryShown: visible('engineSummary'), summary: $('engineSummaryText').textContent,
        change: $('engineChange').textContent, setupShown: visible('engineSetup'), setupText: $('engineSetupText').textContent,
        openLabel: $('engineOpenApp').textContent, formFields: ['engineForm', 'apiKey', 'provider', 'model'].filter((id) => $(id)) };
      $(card.summaryShown ? 'engineChange' : 'engineOpenApp').click();
      await sleep(100);
      return { card, sent: window.__log.filter((m) => m.type === 'open-app'), notice: visible('engineNotice') && $('engineNotice').textContent,
        noticeCls: $('engineNotice').className };
    },
    async 'perm'() {
      await waitFor(() => !document.body.classList.contains('loading'));
      await sleep(100);
      return { banner: visible('banner') && $('bannerText').textContent, action: $('bannerAction').textContent,
        status: $('statusText').textContent, openNetflixShown: visible('openNetflix') };
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
    async 'slider-drag'() {
      await waitFor(() => !document.body.classList.contains('loading'), 6000);
      const previews = [];
      const send = browser.tabs.sendMessage;
      browser.tabs.sendMessage = (id, m) => { if (m.type === 'preview-display') previews.push(m); return send(id, m); };
      const slider = $('fontScale');
      const storedDuring = [];
      for (const v of ['1.1', '1.2', '1.3']) {
        slider.value = v;
        fire(slider, 'input');
        await sleep(40);
        storedDuring.push(window.__store.settings.fontScale);
      }
      fire(slider, 'change'); // let go
      await sleep(30);
      return { previews, storedDuring, storedAfter: window.__store.settings.fontScale, shown: $('fontScaleValue').textContent };
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

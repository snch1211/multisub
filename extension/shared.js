// Shared constants and pure helpers, loaded as a plain script before
// background.js, content.js and popup.js (no modules: Safari's extension
// contexts load these as classic scripts). Everything hangs off
// globalThis.MS so the three contexts agree on defaults, cache keys and
// user-facing wording without copy-pasting them.
//
// Nothing in here touches browser.* APIs or the DOM, so it can be loaded into
// a Node vm context and tested directly.
(function (root) {
  'use strict';

  // Overlay subtitle style. The single source of truth is the app's
  // config.json (MultiSubConfig.styles, delivered on every native `ping`);
  // these defaults only apply before the app has ever sent anything, and
  // must stay in sync with SubtitleStyle in Shared/Config.swift.
  const DEFAULT_STYLES = Object.freeze({
    textColor: '#ffffff',
    backgroundColor: '#000000',
    backgroundOpacity: 0.5,
    outlineEnabled: true,
    outlineColor: '#000000',
    fontFamily: '"Netflix Sans", "Helvetica Neue", "PingFang TC", "Noto Sans TC", sans-serif',
    lineHeight: 1.35,
    boldEnabled: false
  });

  // `name` is the language's name in Traditional Chinese, for sentences such
  // as 「這部片沒有 Netflix 官方的日文字幕」; `label` is what the pickers show.
  const LANGUAGES = Object.freeze([
    { code: 'zh-TW', label: '繁體中文', name: '繁體中文' },
    { code: 'zh-CN', label: '简体中文', name: '簡體中文' },
    { code: 'en', label: 'English', name: '英文' },
    { code: 'ja', label: '日本語', name: '日文' },
    { code: 'ko', label: '한국어', name: '韓文' },
    { code: 'es', label: 'Español', name: '西班牙文' },
    { code: 'fr', label: 'Français', name: '法文' },
    { code: 'de', label: 'Deutsch', name: '德文' },
    { code: 'pt', label: 'Português', name: '葡萄牙文' },
    { code: 'vi', label: 'Tiếng Việt', name: '越南文' },
    { code: 'th', label: 'ไทย', name: '泰文' },
    { code: 'id', label: 'Bahasa Indonesia', name: '印尼文' }
  ]);

  // The mode a new install starts in, and what an unset or unknown mode
  // means: Netflix's own second-language subtitles need no AI and no setup,
  // so bilingual subtitles show up without the user choosing anything.
  // Same as SharedPrefs.defaultMode in Shared/Config.swift.
  const DEFAULT_MODE = 'netflix';
  // Second language when the system's preferred language isn't one of
  // LANGUAGES. Same as LanguageNames.fallbackTargetLang in Swift.
  const FALLBACK_TARGET_LANG = 'zh-TW';

  // Chinese, plus the Chinese languages macOS lists on their own (yue
  // Cantonese, wuu Shanghainese), each with the code its tag maps to when it
  // names neither a script nor a region: CLDR's likely subtags (zh →
  // zh-Hans-CN, yue → yue-Hant-HK, wuu → wuu-Hans-CN).
  const CHINESE_DEFAULTS = Object.freeze({ zh: 'zh-CN', yue: 'zh-TW', wuu: 'zh-CN' });

  // Maps one BCP 47 tag ("zh-Hant-TW", "ja-JP", "en_US") to a LANGUAGES
  // code, or '' when we don't offer that language. Chinese (see
  // CHINESE_DEFAULTS) goes by its script subtag when there is one
  // (zh-Hans-HK is Simplified), else by its region (TW, HK and MO are
  // Traditional; CN, SG and MY Simplified), else by CHINESE_DEFAULTS. Every
  // other language matches on its primary subtag, so pt-BR is pt and es-419
  // is es. Extensions ("-u-...", "-x-...") and ICU keywords ("@...") are
  // ignored.
  //
  // yue and wuu count as Chinese because Safari's navigator.language
  // already folds them into zh-* (a yue-Hans-CN system gives "zh-CN", a
  // yue-Hant-HK one "zh-HK"), while the app's Locale.preferredLanguages
  // keeps "yue-Hans-CN"; mapping them here lands both sides on one code.
  //
  // Must behave exactly like LanguageNames.supportedLanguage(for:) in
  // Shared/LanguageNames.swift: the app and the extension each work out the
  // default second language on their own, and must arrive at the same one.
  function supportedLanguageFor(tag) {
    let parts = String(tag || '').split('@')[0].toLowerCase().split(/[-_]/).filter(Boolean);
    const singleton = parts.findIndex((p) => p.length === 1);
    if (singleton >= 0) parts = parts.slice(0, singleton);
    if (!parts.length) return '';
    if (Object.prototype.hasOwnProperty.call(CHINESE_DEFAULTS, parts[0])) {
      const rest = parts.slice(1);
      if (rest.includes('hant')) return 'zh-TW';
      if (rest.includes('hans')) return 'zh-CN';
      if (rest.some((p) => p === 'tw' || p === 'hk' || p === 'mo')) return 'zh-TW';
      if (rest.some((p) => p === 'cn' || p === 'sg' || p === 'my')) return 'zh-CN';
      return CHINESE_DEFAULTS[parts[0]];
    }
    const hit = LANGUAGES.find((l) => l.code === parts[0]);
    return hit ? hit.code : '';
  }

  // The default second language from the system's preferred languages, most
  // preferred first: the first one decides, else FALLBACK_TARGET_LANG. Only
  // the first, because Safari's navigator.languages holds just that one
  // while the app sees the whole list (Locale.preferredLanguages); looking
  // further down would let the two sides pick different defaults. Same as
  // LanguageNames.defaultTargetLang(preferredLanguages:) in Swift.
  function defaultTargetLang(locales) {
    const first = [].concat(locales == null ? [] : locales)[0];
    return supportedLanguageFor(first) || FALLBACK_TARGET_LANG;
  }

  // navigator.languages where there is one (content script, popup and
  // background page all have it), else nothing (a Node test context).
  function systemLanguages() {
    try {
      const nav = root.navigator;
      if (nav && nav.languages && nav.languages.length) return Array.from(nav.languages);
      if (nav && nav.language) return [nav.language];
    } catch (e) { /* no navigator */ }
    return [];
  }

  // Defaults are never stamped: prefsUpdatedAt stays 0 until the user picks
  // a mode, language or level, so a default can't win the newest-wins sync
  // (reconcilePrefs) over a choice made in the app.
  const DEFAULT_SETTINGS = Object.freeze({
    enabled: true,
    mode: DEFAULT_MODE,
    targetLang: defaultTargetLang(systemLanguages()),
    annotateLevel: 'B1',
    fontScale: 1,
    bottomOffset: 10, // percent from the bottom of the player
    styles: DEFAULT_STYLES,
    // Netflix's own subtitle element is hidden and MultiSub draws both lines,
    // so the two never collide with Netflix's positioning.
    mergedMode: true,
    // Timestamp of the last explicit change to mode/targetLang/annotateLevel;
    // compared with the app's config.prefs.updatedAt (newest wins).
    prefsUpdatedAt: 0
  });

  // `short` fits the popup's three-way segmented control.
  const MODES = Object.freeze([
    { id: 'netflix', label: 'Netflix 雙語字幕', short: 'Netflix 字幕',
      desc: '疊上 Netflix 官方的第二語言字幕，免設定', needsEngine: false },
    { id: 'translate', label: 'AI 翻譯雙語字幕', short: 'AI 翻譯',
      desc: '用 AI 翻譯原文，每部片都能雙語', needsEngine: true },
    { id: 'annotate', label: '生字標註', short: '生字標註',
      desc: '在原文的難字後面標上意思，適合學語言', needsEngine: true }
  ]);

  const LEVELS = Object.freeze([
    { id: 'A2', label: 'A2 初級' },
    { id: 'B1', label: 'B1 中級' },
    { id: 'B2', label: 'B2 中高級' },
    { id: 'C1', label: 'C1 高級' }
  ]);

  // Error codes the native side (and background.js) report; see
  // ARCHITECTURE §5.1. Short enough for the overlay hint and the popup's
  // status line.
  const ERROR_TEXT = Object.freeze({
    'native-unavailable': '連不到 MultiSub App，請打開 App 再試一次',
    'engine-not-ready': '還沒設定 AI 引擎，點 Safari 工具列的 MultiSub 圖示設定',
    'model-not-ready': '本機模型還沒下載，請到 MultiSub App 下載',
    'auth-failed': 'API Key 無效或已過期，請到 MultiSub App 重新貼上',
    'rate-limited': 'AI 服務的額度用完或請求太頻繁，請稍後再試',
    'network': '連不上 AI 服務，請檢查網路',
    'provider-error': 'AI 服務暫時出錯，請稍後再試',
    // set-engine refuses a cloud provider the user hasn't agreed to send
    // subtitles to yet (App Review 5.1.2(i)); the popup turns this into its
    // confirmation step, so the text mostly shows up in the overlay.
    'consent-required': '還沒同意把字幕送到這個 AI 服務，點 Safari 工具列的 MultiSub 圖示確認'
  });

  const NETFLIX_ORIGINS = Object.freeze(['*://*.netflix.com/*']);

  // ---------------------------------------------------------------------------
  // Languages
  // ---------------------------------------------------------------------------

  // Netflix uses zh-Hant/zh-Hans (script subtags) for Chinese while our
  // settings use zh-TW/zh-CN; every other language compares on the primary
  // subtag, so pt-BR matches pt and es-419 matches es.
  function normalizeBcp47(code) {
    if (!code) return '';
    const c = String(code).toLowerCase();
    if (c.indexOf('zh') === 0) {
      if (/hant|-tw|-hk|-mo/.test(c)) return 'zh-hant';
      if (/hans|-cn|-sg/.test(c)) return 'zh-hans';
      return 'zh';
    }
    return c.split('-')[0];
  }

  function sameLanguage(a, b) {
    const na = normalizeBcp47(a);
    return !!na && na === normalizeBcp47(b);
  }

  function languageName(code) {
    const hit = LANGUAGES.find((l) => l.code === code) ||
      LANGUAGES.find((l) => sameLanguage(l.code, code));
    return hit ? hit.name : String(code || '');
  }

  function modeById(id) {
    return MODES.find((m) => m.id === id) || null;
  }

  // ---------------------------------------------------------------------------
  // Cues
  // ---------------------------------------------------------------------------

  // Aligns source cues with another track's cues by time overlap. Each source
  // cue gets the text of every reference cue that overlaps it (joined in
  // chronological order, so one-to-many and many-to-one splits both survive),
  // or null when nothing overlaps. Both inputs are [{start, end, text}] sorted
  // by start, as the WebVTT/TTML parsers in inject.js produce them.
  function alignCues(sourceCues, refCues) {
    const src = Array.isArray(sourceCues) ? sourceCues : [];
    const result = new Array(src.length).fill(null);
    if (!Array.isArray(refCues) || !refCues.length) return result;
    let refIdx = 0;
    for (let i = 0; i < src.length; i++) {
      const s = src[i];
      // Skip reference cues that end before this source cue starts, but keep
      // any that might still overlap a later source cue too.
      while (refIdx < refCues.length - 1 && refCues[refIdx].end < s.start) refIdx++;
      const matched = [];
      for (let j = refIdx; j < refCues.length; j++) {
        const ref = refCues[j];
        if (ref.start > s.end) break;
        const overlap = Math.min(s.end, ref.end) - Math.max(s.start, ref.start);
        if (overlap > 0) matched.push(ref.text);
      }
      if (matched.length) result[i] = matched.join(' ');
    }
    return result;
  }

  // Splits cue indices into scene-sized chunks for annotate requests:
  // consecutive cues, at most maxSize per chunk, cut early at a pause longer
  // than gapSec once the chunk already holds minSize cues. Cutting at pauses
  // keeps a scene's lines in one request (so the model sees the context it
  // needs), while the minimum stops a chatty scene with many short pauses from
  // turning into lots of tiny, expensive requests. Returns half-open ranges.
  function chunkCues(starts, maxSize, minSize, gapSec) {
    const n = Array.isArray(starts) ? starts.length : 0;
    const max = Math.max(1, maxSize || 16);
    const min = Math.min(max, Math.max(1, minSize || 8));
    const gap = gapSec == null ? 5 : gapSec;
    const out = [];
    let begin = 0;
    for (let i = 1; i < n; i++) {
      const size = i - begin;
      const pause = Number(starts[i]) - Number(starts[i - 1]);
      if (size >= max || (size >= min && pause > gap)) {
        out.push([begin, i]);
        begin = i;
      }
    }
    if (n > 0) out.push([begin, n]);
    return out;
  }

  // Fixed-size ranges, for translate batches.
  function fixedChunks(length, size) {
    const out = [];
    const step = Math.max(1, size || 12);
    for (let i = 0; i < length; i += step) out.push([i, Math.min(i + step, length)]);
    return out;
  }

  // Orders chunk ranges so the one containing `index` comes first, then the
  // chunks after it, then (wrapping around) the ones before it. Used both for
  // a job's initial queue (start where the viewer is) and for re-prioritising
  // after a seek.
  function orderChunks(chunks, index, total) {
    const n = total || chunks.reduce((m, c) => Math.max(m, c[1]), 0);
    const at = Math.max(0, Math.min(index || 0, Math.max(0, n - 1)));
    const rank = (c) => (c[1] <= at ? c[0] + n : c[0]);
    return chunks.slice().sort((a, b) => rank(a) - rank(b));
  }

  // A cue is held this long past its end to bridge the tiny gaps Netflix
  // leaves between consecutive cues.
  const CUE_HOLD_SEC = 0.15;

  // Cues are sorted by start, but their ends aren't: an SDH sign or a second
  // speaker can overlap a longer cue that started earlier. maxEnd[i] is the
  // latest end among cues[0..i], so a backwards scan can stop as soon as no
  // earlier cue can still be on screen. Cached per array (the cue arrays are
  // replaced, never edited, when a track loads); the length check is only a
  // guard against an array that was edited in place anyway.
  const maxEndCache = new WeakMap();
  function maxEnds(cues) {
    const hit = maxEndCache.get(cues);
    if (hit && hit.length === cues.length) return hit;
    const out = new Array(cues.length);
    let m = -Infinity;
    for (let i = 0; i < cues.length; i++) {
      const end = Number(cues[i].end);
      if (end > m) m = end;
      out[i] = m;
    }
    maxEndCache.set(cues, out);
    return out;
  }

  // Index of the last cue with start <= t, or -1.
  function lastStartedAt(cues, t) {
    let lo = 0, hi = cues.length - 1, ans = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (cues[mid].start <= t) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return ans;
  }

  // Index of the cue showing at time t, or -1. When cues overlap, the one
  // that started last wins, and an earlier, longer cue comes back once the
  // shorter one inside it has ended (instead of the line going blank).
  function findCueIndex(cues, t) {
    if (!Array.isArray(cues) || !cues.length) return -1;
    const ans = lastStartedAt(cues, t);
    if (ans < 0) return -1;
    if (t <= cues[ans].end + CUE_HOLD_SEC) return ans;
    const maxEnd = maxEnds(cues);
    for (let k = ans - 1; k >= 0 && t <= maxEnd[k] + CUE_HOLD_SEC; k--) {
      if (t <= cues[k].end + CUE_HOLD_SEC) return k;
    }
    return -1;
  }

  // Index of the cue showing at time t or, between cues, the next one to
  // start; clamped to the last cue after the end. Searches on start times
  // (which are sorted) rather than end times (which aren't, see maxEnds).
  function cueIndexAtOrAfter(cues, t) {
    if (!Array.isArray(cues) || !cues.length) return 0;
    const showing = findCueIndex(cues, t);
    if (showing >= 0) return showing;
    return Math.min(lastStartedAt(cues, t) + 1, cues.length - 1);
  }

  // ---------------------------------------------------------------------------
  // Cache keys (storage.local). All share the 'ms:' prefix so they share one
  // LRU pool in background.js. The translate key keeps its original format so
  // caches written by earlier versions stay valid.
  // ---------------------------------------------------------------------------
  const CACHE_PREFIX = 'ms:';
  const GLOSSARY_PREFIX = 'ms:gl:';
  const ANNOTATE_PREFIX = 'ms:an:';

  function cacheGroup(movieId, targetLang, sourceLang) {
    return movieId + ':' + targetLang + ':' + (sourceLang || 'unknown');
  }
  function translateKey(movieId, targetLang, sourceLang) {
    return CACHE_PREFIX + cacheGroup(movieId, targetLang, sourceLang);
  }
  function glossaryKey(movieId, targetLang, sourceLang) {
    return GLOSSARY_PREFIX + cacheGroup(movieId, targetLang, sourceLang);
  }
  function annotateKey(movieId, targetLang, sourceLang) {
    return ANNOTATE_PREFIX + cacheGroup(movieId, targetLang, sourceLang);
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  // Fills in defaults and drops invalid values. A missing, null or unknown
  // mode becomes DEFAULT_MODE, without touching prefsUpdatedAt. An install
  // from before modes existed (v1.0) has a stored object with neither a
  // `mode` nor a `prefsUpdatedAt` key: it starts in DEFAULT_MODE like a new
  // install, and keeps its own mergedMode, which back then defaulted to off,
  // so upgrading doesn't change its layout. (Objects written through
  // storedSettings may lack `mode` too, but always carry prefsUpdatedAt.)
  function mergeSettings(stored) {
    const s = stored && typeof stored === 'object' ? stored : null;
    const out = Object.assign({}, DEFAULT_SETTINGS, s || {});
    out.styles = Object.assign({}, DEFAULT_STYLES, (s && s.styles) || {});
    if (!modeById(out.mode)) out.mode = DEFAULT_MODE;
    if (typeof out.targetLang !== 'string' || !out.targetLang) out.targetLang = DEFAULT_SETTINGS.targetLang;
    if (!LEVELS.some((l) => l.id === out.annotateLevel)) out.annotateLevel = DEFAULT_SETTINGS.annotateLevel;
    out.enabled = out.enabled !== false;
    out.fontScale = Number(out.fontScale) > 0 ? Number(out.fontScale) : DEFAULT_SETTINGS.fontScale;
    out.bottomOffset = Number.isFinite(Number(out.bottomOffset)) ? Number(out.bottomOffset) : DEFAULT_SETTINGS.bottomOffset;
    out.prefsUpdatedAt = Number(out.prefsUpdatedAt) || 0;
    const has = (key) => Object.prototype.hasOwnProperty.call(s, key);
    const legacy = !!s && !has('mode') && !has('prefsUpdatedAt');
    if (legacy) out.mergedMode = s.mergedMode === true;
    else out.mergedMode = out.mergedMode !== false;
    return out;
  }

  // The object to write to storage.local for `settings` (a mergeSettings
  // result): everything except the shared preferences nobody has chosen.
  // While prefsUpdatedAt is 0, mode and annotateLevel are always defaults,
  // and so is targetLang unless it was read from a v1.0 object, where it
  // was the user's pick from before preferences were synced (a v1.0 value
  // equal to today's default is indistinguishable from it and goes too).
  // Left out, they are filled in again by mergeSettings on every read, so
  // the second language keeps following the system language, as it does
  // in the app (SharedPrefs.effectiveTargetLang). Saved as they are, a drag
  // of the subtitles or a display change would freeze today's default into
  // storage, and the extension would then disagree with the app as soon as
  // the system language changed, with nothing stamped for the sync to
  // repair. Every write of `settings` goes through here.
  function storedSettings(settings) {
    const out = Object.assign({}, settings);
    if (Number(out.prefsUpdatedAt) > 0) return out;
    delete out.mode;
    delete out.annotateLevel;
    if (out.targetLang === DEFAULT_SETTINGS.targetLang) delete out.targetLang;
    out.prefsUpdatedAt = 0;
    return out;
  }

  function prefsOf(settings) {
    return {
      mode: settings.mode,
      targetLang: settings.targetLang,
      annotateLevel: settings.annotateLevel,
      updatedAt: settings.prefsUpdatedAt || 0
    };
  }

  // Newest updatedAt wins between storage.local and the app's config.prefs.
  // A field the app has never set is absent from nativePrefs and keeps the
  // local value; defaults are never stamped on either side, so they never
  // win over an explicit choice. Returns {adopt: settings-with-native-prefs
  // | null, push: bool}.
  function reconcilePrefs(settings, nativePrefs) {
    const local = settings.prefsUpdatedAt || 0;
    const remote = nativePrefs && Number(nativePrefs.updatedAt) || 0;
    if (remote > local) {
      const next = mergeSettings(Object.assign({}, settings, {
        mode: nativePrefs.mode != null ? nativePrefs.mode : settings.mode,
        targetLang: nativePrefs.targetLang || settings.targetLang,
        annotateLevel: nativePrefs.annotateLevel || settings.annotateLevel,
        prefsUpdatedAt: remote
      }));
      return { adopt: next, push: false };
    }
    return { adopt: null, push: local > remote };
  }

  function errorText(code) {
    if (ERROR_TEXT[code]) return ERROR_TEXT[code];
    return '出了點問題（' + (code || 'unknown') + '）';
  }

  // ---------------------------------------------------------------------------
  // Annotation matching
  // ---------------------------------------------------------------------------

  // findTerm must accept exactly the terms Swift's validator accepts
  // (Prompts.termOccurs/normalizeForMatch/usesSpacedScript in
  // Shared/Prompts.swift): an annotation native kept but the overlay can't
  // place is silently lost. Keep the two in step.
  const WORD_CHAR = /[\p{L}\p{M}\p{N}]/u;
  const ALPHABETIC = /\p{Alphabetic}/u;

  // Same as normalizeForMatch: curly apostrophes (U+2018, U+2019) become ',
  // line breaks become spaces. Every replacement is one UTF-16 unit for one,
  // so offsets into the normalized line are offsets into the original line
  // too. Non-ASCII characters in a regular expression are written as \u
  // escapes: decoded in a legacy encoding (Big5, GBK, Shift_JIS), the
  // character itself can swallow the "]" after it and stop this file from
  // parsing (see background.html and tests/extension/layout.test.js).
  function normalizeForMatch(s) {
    return String(s).replace(/[\u2018\u2019]/g, "'").replace(/\n/g, ' ');
  }

  // Same as usesSpacedScript: every alphabetic character is Latin, Greek or
  // Cyrillic (non-letters such as digits, spaces and punctuation don't count).
  function usesSpacedScript(s) {
    for (const ch of s) {
      if (!ALPHABETIC.test(ch)) continue;
      const c = ch.codePointAt(0);
      const spaced = c <= 0x024F || (c >= 0x1E00 && c <= 0x1EFF) || // Latin
        (c >= 0x0370 && c <= 0x03FF) || (c >= 0x1F00 && c <= 0x1FFF) || // Greek
        (c >= 0x0400 && c <= 0x052F); // Cyrillic
      if (!spaced) return false;
    }
    return true;
  }

  function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  // Last code point before `index` / first at `index`, '' at the edges.
  function codePointBefore(text, index) {
    return index > 0 ? Array.from(text.slice(Math.max(0, index - 2), index)).pop() : '';
  }
  function codePointAt(text, index) {
    return index < text.length ? Array.from(text.slice(index, index + 2))[0] : '';
  }

  // First occurrence of `term` in `text` as [start, end), or null. Matches
  // like Swift's termOccurs: case-insensitive after normalizeForMatch; a term
  // written only in Latin/Greek/Cyrillic must sit on word boundaries (no
  // letter, mark or digit right before or after, so "keys" never matches
  // inside "monkeys") and each space in it matches any run of whitespace;
  // any other term (Chinese, Japanese, Arabic, …) is a plain substring.
  function findTerm(text, term) {
    const t = normalizeForMatch(term || '').replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, '');
    if (!t) return null;
    const line = normalizeForMatch(text || '');
    const spaced = usesSpacedScript(t);
    const pattern = spaced ? escapeRegExp(t).replace(/ /g, '\\s+') : escapeRegExp(t);
    let re;
    try { re = new RegExp(pattern, 'giu'); } catch (e) { return null; }
    let m;
    while ((m = re.exec(line)) !== null) {
      const start = m.index;
      const end = start + m[0].length;
      if (!m[0].length) { re.lastIndex++; continue; }
      if (spaced && (WORD_CHAR.test(codePointBefore(line, start)) || WORD_CHAR.test(codePointAt(line, end)))) {
        re.lastIndex = start + 1;
        continue;
      }
      return [start, end];
    }
    return null;
  }

  // Turns a line plus its annotations into ordered render segments:
  // [{text}, {text, gloss}, …]. Each term is matched at its first occurrence;
  // where two matches overlap, the one that starts first wins (the longer one
  // on a tie, so "come up with" beats "come"). Terms that don't occur are
  // dropped, never guessed at.
  function matchAnnotations(lineText, annotations) {
    const text = String(lineText || '');
    if (!text) return [];
    const list = Array.isArray(annotations) ? annotations : [];
    const seen = new Set();
    const matches = [];
    for (const a of list) {
      if (!a || typeof a.term !== 'string' || typeof a.gloss !== 'string') continue;
      const key = a.term.trim().toLowerCase();
      if (!key || !a.gloss.trim() || seen.has(key)) continue;
      seen.add(key);
      const hit = findTerm(text, a.term);
      if (hit) matches.push({ start: hit[0], end: hit[1], gloss: a.gloss.trim() });
    }
    matches.sort((a, b) => a.start - b.start || (b.end - b.start) - (a.end - a.start));
    const segments = [];
    let pos = 0;
    for (const m of matches) {
      if (m.start < pos) continue;
      if (m.start > pos) segments.push({ text: text.slice(pos, m.start) });
      segments.push({ text: text.slice(m.start, m.end), gloss: m.gloss });
      pos = m.end;
    }
    if (pos < text.length) segments.push({ text: text.slice(pos) });
    return segments;
  }

  root.MS = Object.freeze({
    DEFAULT_STYLES: DEFAULT_STYLES,
    DEFAULT_SETTINGS: DEFAULT_SETTINGS,
    DEFAULT_MODE: DEFAULT_MODE,
    FALLBACK_TARGET_LANG: FALLBACK_TARGET_LANG,
    LANGUAGES: LANGUAGES,
    MODES: MODES,
    LEVELS: LEVELS,
    ERROR_TEXT: ERROR_TEXT,
    NETFLIX_ORIGINS: NETFLIX_ORIGINS,
    CACHE_PREFIX: CACHE_PREFIX,
    GLOSSARY_PREFIX: GLOSSARY_PREFIX,
    ANNOTATE_PREFIX: ANNOTATE_PREFIX,
    normalizeBcp47: normalizeBcp47,
    sameLanguage: sameLanguage,
    languageName: languageName,
    supportedLanguageFor: supportedLanguageFor,
    defaultTargetLang: defaultTargetLang,
    modeById: modeById,
    alignCues: alignCues,
    chunkCues: chunkCues,
    fixedChunks: fixedChunks,
    orderChunks: orderChunks,
    findCueIndex: findCueIndex,
    cueIndexAtOrAfter: cueIndexAtOrAfter,
    cacheGroup: cacheGroup,
    translateKey: translateKey,
    glossaryKey: glossaryKey,
    annotateKey: annotateKey,
    mergeSettings: mergeSettings,
    storedSettings: storedSettings,
    prefsOf: prefsOf,
    reconcilePrefs: reconcilePrefs,
    errorText: errorText,
    findTerm: findTerm,
    matchAnnotations: matchAnnotations
  });
})(typeof globalThis !== 'undefined' ? globalThis : this);

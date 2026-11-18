'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');

const EXT = process.env.EXT || require('path').resolve(__dirname, '../../extension');
const ctx = vm.createContext({});
vm.runInContext(fs.readFileSync(EXT + '/shared.js', 'utf8'), ctx, { filename: 'shared.js' });
const MS = ctx.MS;
// Objects from another realm: compare via JSON.
const j = (x) => JSON.parse(JSON.stringify(x));
let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('ok   ' + name); }
  catch (e) { console.log('FAIL ' + name + '\n     ' + e.message); process.exitCode = 1; }
}

test('MS is frozen and has the documented surface', () => {
  assert.ok(Object.isFrozen(MS));
  for (const k of ['DEFAULT_STYLES', 'DEFAULT_SETTINGS', 'LANGUAGES', 'MODES', 'LEVELS', 'normalizeBcp47',
    'alignCues', 'chunkCues', 'translateKey', 'glossaryKey', 'annotateKey', 'mergeSettings', 'ERROR_TEXT', 'matchAnnotations',
    'DEFAULT_MODE', 'FALLBACK_TARGET_LANG', 'supportedLanguageFor', 'defaultTargetLang', 'storedSettings']) {
    assert.ok(k in MS, k);
  }
  assert.equal(MS.LANGUAGES.length, 12);
  assert.equal(MS.DEFAULT_MODE, 'netflix');
  assert.deepEqual(j(MS.MODES.map((m) => [m.id, m.needsEngine])), [['netflix', false], ['translate', true], ['annotate', true]]);
  assert.deepEqual(j(MS.LEVELS.map((l) => l.id)), ['A2', 'B1', 'B2', 'C1']);
  assert.deepEqual(j(MS.LEVELS.map((l) => l.label)), ['A2 初級', 'B1 中級', 'B2 中高級', 'C1 高級']);
  for (const code of ['native-unavailable', 'engine-not-ready', 'model-not-ready', 'auth-failed', 'rate-limited', 'network', 'provider-error']) {
    assert.ok(MS.ERROR_TEXT[code], code);
  }
  assert.match(MS.errorText('weird-code'), /weird-code/);
});

test('DEFAULT_SETTINGS', () => {
  assert.deepEqual(j(MS.DEFAULT_SETTINGS), {
    enabled: true, mode: 'netflix', targetLang: 'zh-TW', annotateLevel: 'B1', fontScale: 1, bottomOffset: 10,
    styles: j(MS.DEFAULT_STYLES), mergedMode: true, prefsUpdatedAt: 0
  });
});

test('normalizeBcp47', () => {
  assert.equal(MS.normalizeBcp47('zh-Hant'), 'zh-hant');
  assert.equal(MS.normalizeBcp47('zh-TW'), 'zh-hant');
  assert.equal(MS.normalizeBcp47('zh-HK'), 'zh-hant');
  assert.equal(MS.normalizeBcp47('zh-Hans'), 'zh-hans');
  assert.equal(MS.normalizeBcp47('zh-CN'), 'zh-hans');
  assert.equal(MS.normalizeBcp47('zh'), 'zh');
  assert.equal(MS.normalizeBcp47('en-US'), 'en');
  assert.equal(MS.normalizeBcp47('pt-BR'), 'pt');
  assert.equal(MS.normalizeBcp47('es-419'), 'es');
  assert.equal(MS.normalizeBcp47(''), '');
  assert.equal(MS.normalizeBcp47(null), '');
  assert.ok(MS.sameLanguage('zh-TW', 'zh-Hant'));
  assert.ok(!MS.sameLanguage('zh-TW', 'zh-Hans'));
  assert.ok(!MS.sameLanguage('', ''));
  assert.equal(MS.languageName('zh-TW'), '繁體中文');
  assert.equal(MS.languageName('ja'), '日文');
});

test('alignCues: overlaps, many-to-one, gaps', () => {
  const src = [
    { start: 0, end: 2, text: 'a' },
    { start: 2.5, end: 5, text: 'b' },
    { start: 10, end: 11, text: 'c' },
    { start: 20, end: 22, text: 'd' }
  ];
  const ref = [
    { start: 0.1, end: 1.9, text: 'A' },
    { start: 2.4, end: 3.5, text: 'B1' },
    { start: 3.6, end: 5.2, text: 'B2' },
    { start: 12, end: 13, text: 'X' },
    { start: 21, end: 23, text: 'D' }
  ];
  assert.deepEqual(j(MS.alignCues(src, ref)), ['A', 'B1 B2', null, 'D']);
  assert.deepEqual(j(MS.alignCues(src, [])), [null, null, null, null]);
  assert.deepEqual(j(MS.alignCues(src, null)), [null, null, null, null]);
  // one reference cue spanning two source cues lands on both
  assert.deepEqual(j(MS.alignCues([{ start: 0, end: 1, text: 'x' }, { start: 1, end: 2, text: 'y' }],
    [{ start: 0, end: 2, text: 'XY' }])), ['XY', 'XY']);
  // touching but not overlapping intervals don't match
  assert.deepEqual(j(MS.alignCues([{ start: 0, end: 1, text: 'x' }], [{ start: 1, end: 2, text: 'Y' }])), [null]);
});

test('chunkCues: max size, min size, gaps', () => {
  // 40 evenly spaced cues, no gaps -> 16 + 16 + 8
  const even = Array.from({ length: 40 }, (_, i) => i * 2);
  assert.deepEqual(j(MS.chunkCues(even)), [[0, 16], [16, 32], [32, 40]]);
  // a 10 s pause after cue 9 (chunk already has 10 >= 8 cues) cuts there
  const gap = Array.from({ length: 30 }, (_, i) => (i < 10 ? i : i + 10));
  assert.deepEqual(j(MS.chunkCues(gap)), [[0, 10], [10, 26], [26, 30]]);
  // a pause before the chunk has 8 cues does not cut
  const early = Array.from({ length: 20 }, (_, i) => (i < 4 ? i : i + 30));
  assert.deepEqual(j(MS.chunkCues(early)), [[0, 16], [16, 20]]);
  // pause of exactly gapSec doesn't count (must be longer)
  const exact = Array.from({ length: 12 }, (_, i) => (i < 8 ? i : i + 4)); // starts[8]-starts[7] = 5
  assert.deepEqual(j(MS.chunkCues(exact)), [[0, 12]]);
  // every chunk respects max, covers everything, in order
  const random = []; let t = 0;
  for (let i = 0; i < 500; i++) { t += (i % 37 === 0) ? 9 : 1.3; random.push(t); }
  const chunks = MS.chunkCues(random);
  let pos = 0;
  for (const [a, b] of chunks) {
    assert.equal(a, pos); assert.ok(b > a); assert.ok(b - a <= 16);
    pos = b;
  }
  assert.equal(pos, 500);
  // non-final chunks cut on a gap are at least min size
  for (const [a, b] of chunks.slice(0, -1)) assert.ok(b - a >= 8, 'chunk ' + a + '-' + b);
  assert.deepEqual(j(MS.chunkCues([])), []);
  assert.deepEqual(j(MS.chunkCues([5])), [[0, 1]]);
  // custom parameters
  assert.deepEqual(j(MS.chunkCues([0, 1, 2, 3, 4, 5], 4, 2, 5)), [[0, 4], [4, 6]]);
});

test('fixedChunks / orderChunks', () => {
  assert.deepEqual(j(MS.fixedChunks(50, 24)), [[0, 24], [24, 48], [48, 50]]);
  const chunks = MS.fixedChunks(100, 10);
  const order = MS.orderChunks(chunks, 35, 100).map((c) => c[0]);
  assert.deepEqual(j(order), [30, 40, 50, 60, 70, 80, 90, 0, 10, 20]);
  assert.deepEqual(j(MS.orderChunks(chunks, 0, 100).map((c) => c[0])), [0, 10, 20, 30, 40, 50, 60, 70, 80, 90]);
  // re-prioritising a partial queue keeps only what was there
  const rest = [[0, 10], [50, 60], [80, 90]];
  assert.deepEqual(j(MS.orderChunks(rest, 55, 100)), [[50, 60], [80, 90], [0, 10]]);
  assert.deepEqual(j(MS.orderChunks(rest, 65, 100)), [[80, 90], [0, 10], [50, 60]]);
});

test('findCueIndex / cueIndexAtOrAfter', () => {
  const cues = [{ start: 1, end: 2 }, { start: 3, end: 4 }, { start: 10, end: 12 }];
  assert.equal(MS.findCueIndex(cues, 0.5), -1);
  assert.equal(MS.findCueIndex(cues, 1.5), 0);
  assert.equal(MS.findCueIndex(cues, 2.1), 0); // bridged 0.15 s
  assert.equal(MS.findCueIndex(cues, 2.5), -1);
  assert.equal(MS.findCueIndex(cues, 11), 2);
  assert.equal(MS.cueIndexAtOrAfter(cues, 0), 0);
  assert.equal(MS.cueIndexAtOrAfter(cues, 2.5), 1);
  assert.equal(MS.cueIndexAtOrAfter(cues, 3.5), 1);
  assert.equal(MS.cueIndexAtOrAfter(cues, 5), 2);
  assert.equal(MS.cueIndexAtOrAfter(cues, 99), 2);
  assert.equal(MS.cueIndexAtOrAfter([], 5), 0);
});

test('cache keys', () => {
  assert.equal(MS.translateKey('81234', 'zh-TW', 'en'), 'ms:81234:zh-TW:en');
  assert.equal(MS.translateKey('81234', 'zh-TW', ''), 'ms:81234:zh-TW:unknown');
  assert.equal(MS.glossaryKey('81234', 'zh-TW', 'en'), 'ms:gl:81234:zh-TW:en');
  assert.equal(MS.annotateKey('81234', 'ja', 'en'), 'ms:an:81234:ja:en');
  assert.ok(MS.translateKey('1', 'a', 'b').startsWith(MS.CACHE_PREFIX));
  assert.ok(MS.annotateKey('1', 'a', 'b').startsWith(MS.CACHE_PREFIX));
});

test('mergeSettings: new install', () => {
  const s = MS.mergeSettings(undefined);
  assert.equal(s.mode, 'netflix');
  assert.equal(s.targetLang, 'zh-TW'); // no navigator here: the fallback
  assert.equal(s.mergedMode, true);
  assert.equal(s.annotateLevel, 'B1');
  assert.equal(s.prefsUpdatedAt, 0);
  assert.notEqual(s.styles, MS.DEFAULT_STYLES); // a copy, safe to mutate
  s.styles.textColor = '#ff0000';
  assert.equal(MS.DEFAULT_STYLES.textColor, '#ffffff');
});

test('mergeSettings: legacy object without mode gets the default mode and keeps its own mergedMode', () => {
  const legacy = { enabled: true, targetLang: 'ja', fontScale: 1.2, bottomOffset: 14,
    styles: { textColor: '#ffff00' }, mergedMode: false };
  const s = MS.mergeSettings(legacy);
  assert.equal(s.mode, 'netflix');
  assert.equal(s.prefsUpdatedAt, 0);
  assert.equal(s.mergedMode, false);
  assert.equal(s.targetLang, 'ja');
  assert.equal(s.fontScale, 1.2);
  assert.equal(s.bottomOffset, 14);
  assert.equal(s.styles.textColor, '#ffff00');
  assert.equal(s.styles.lineHeight, 1.35); // filled from defaults
  assert.equal(s.annotateLevel, 'B1');
  assert.equal(MS.mergeSettings({ enabled: false, targetLang: 'en', mergedMode: true }).mergedMode, true);
  // pre-merged-mode installs had no key at all: that meant "off"
  assert.equal(MS.mergeSettings({ enabled: true, targetLang: 'en' }).mergedMode, false);
  assert.equal(MS.mergeSettings({ enabled: false }).enabled, false);
});

test('mergeSettings: current object, validation', () => {
  const s = MS.mergeSettings({ mode: 'annotate', annotateLevel: 'C1', targetLang: 'ko', prefsUpdatedAt: 5 });
  assert.equal(s.mode, 'annotate');
  assert.equal(s.mergedMode, true); // missing in a current-format object -> default on
  assert.equal(s.annotateLevel, 'C1');
  assert.equal(MS.mergeSettings({ mode: 'bogus' }).mode, 'netflix');
  // a null mode saved by an older build (before the default existed)
  assert.equal(MS.mergeSettings({ mode: null, targetLang: 'ko' }).mode, 'netflix');
  assert.equal(MS.mergeSettings({ mode: null, targetLang: 'ko' }).targetLang, 'ko');
  assert.equal(MS.mergeSettings({ mode: 'netflix', annotateLevel: 'Z9' }).annotateLevel, 'B1');
  assert.equal(MS.mergeSettings({ mode: 'netflix', mergedMode: false }).mergedMode, false);
});

test('reconcilePrefs', () => {
  const local = MS.mergeSettings({ mode: 'netflix', targetLang: 'zh-TW', prefsUpdatedAt: 100 });
  const newer = MS.reconcilePrefs(local, { mode: 'annotate', targetLang: 'ja', annotateLevel: 'B2', updatedAt: 200 });
  assert.equal(newer.push, false);
  assert.equal(newer.adopt.mode, 'annotate');
  assert.equal(newer.adopt.targetLang, 'ja');
  assert.equal(newer.adopt.annotateLevel, 'B2');
  assert.equal(newer.adopt.prefsUpdatedAt, 200);
  const older = MS.reconcilePrefs(local, { mode: 'translate', updatedAt: 50 });
  assert.equal(older.adopt, null);
  assert.equal(older.push, true);
  const same = MS.reconcilePrefs(local, { mode: 'netflix', updatedAt: 100 });
  assert.deepEqual(j(same), { adopt: null, push: false });
  assert.deepEqual(j(MS.reconcilePrefs(MS.mergeSettings(null), null)), { adopt: null, push: false });
  assert.deepEqual(j(MS.prefsOf(local)), { mode: 'netflix', targetLang: 'zh-TW', annotateLevel: 'B1', updatedAt: 100 });
});

test('defaults never bump prefsUpdatedAt, so they never win the sync', () => {
  const defaults = MS.mergeSettings(null);
  assert.equal(defaults.prefsUpdatedAt, 0);
  for (const stored of [undefined, {}, { mode: null }, { mode: 'bogus' }, { fontScale: 1.5 }]) {
    assert.equal(MS.mergeSettings(stored).prefsUpdatedAt, 0, JSON.stringify(stored));
  }
  // Nothing to push while only defaults are in use, whatever the app has.
  assert.equal(MS.reconcilePrefs(defaults, null).push, false);
  assert.equal(MS.reconcilePrefs(defaults, { updatedAt: 0 }).push, false);
  assert.equal(MS.reconcilePrefs(defaults, { mode: 'netflix', updatedAt: 0 }).adopt, null);
  // Any explicit choice in the app wins over them.
  const app = MS.reconcilePrefs(defaults, { mode: 'annotate', targetLang: 'ko', annotateLevel: 'C1', updatedAt: 1 });
  assert.equal(app.push, false);
  assert.deepEqual(j(MS.prefsOf(app.adopt)), { mode: 'annotate', targetLang: 'ko', annotateLevel: 'C1', updatedAt: 1 });
  // A field the app never set keeps the local value instead of a default.
  const partial = MS.reconcilePrefs(MS.mergeSettings({ mode: 'translate', targetLang: 'ja', prefsUpdatedAt: 3 }),
    { targetLang: 'ko', updatedAt: 4 });
  assert.equal(partial.adopt.mode, 'translate');
  assert.equal(partial.adopt.targetLang, 'ko');
  // Round trip through storage (JSON) stays unstamped.
  assert.equal(MS.mergeSettings(j(defaults)).prefsUpdatedAt, 0);
});

test('supportedLanguageFor: system language tags to LANGUAGES codes', () => {
  const cases = {
    // Traditional Chinese: script first, then region
    'zh-Hant-TW': 'zh-TW', 'zh-TW': 'zh-TW', 'zh-HK': 'zh-TW', 'zh-MO': 'zh-TW', 'zh-Hant': 'zh-TW',
    'zh-Hant-HK': 'zh-TW', 'zh_TW': 'zh-TW', 'ZH-HANT-tw': 'zh-TW', 'zh-Hant-CN': 'zh-TW',
    // Simplified Chinese; a bare zh is Simplified (CLDR likely subtags)
    'zh-Hans-CN': 'zh-CN', 'zh-CN': 'zh-CN', 'zh-SG': 'zh-CN', 'zh-Hans': 'zh-CN', 'zh-Hans-HK': 'zh-CN',
    'zh-Hans-TW': 'zh-CN', 'zh-MY': 'zh-CN', 'zh': 'zh-CN',
    // Cantonese and Shanghainese count as Chinese (Safari's navigator.language
    // already turns them into zh-*): script, then region, then their usual script
    'yue-Hans-CN': 'zh-CN', 'yue-Hant-HK': 'zh-TW', 'yue-Hant-MO': 'zh-TW', 'yue_Hans': 'zh-CN',
    'yue-HK': 'zh-TW', 'yue-CN': 'zh-CN', 'yue': 'zh-TW',
    'wuu-Hans-CN': 'zh-CN', 'wuu-Hant-TW': 'zh-TW', 'wuu-TW': 'zh-TW', 'wuu': 'zh-CN',
    // everything else by primary subtag
    'ja-JP': 'ja', 'ja': 'ja', 'ko-KR': 'ko', 'en-US': 'en', 'en-GB': 'en', 'en_TW': 'en', 'es-419': 'es',
    'pt-BR': 'pt', 'fr-CA': 'fr', 'de-DE': 'de', 'vi-VN': 'vi', 'th-TH': 'th', 'id-ID': 'id',
    // extensions and ICU keywords don't count
    'zh-TW-u-ca-roc': 'zh-TW', 'en-US-x-private': 'en', 'en_US@calendar=japanese': 'en', 'zh-u-nu-hanidec-hk': 'zh-CN',
    // not offered
    'fi-FI': '', 'nan-Hant-TW': '', 'nb-NO': '', 'x-klingon': '', 'zhx': '', '': '', '-': ''
  };
  for (const [tag, want] of Object.entries(cases)) assert.equal(MS.supportedLanguageFor(tag), want, tag);
  assert.equal(MS.supportedLanguageFor(null), '');
  assert.equal(MS.supportedLanguageFor(undefined), '');
  // every code it returns is one the pickers offer
  const codes = new Set(MS.LANGUAGES.map((l) => l.code));
  for (const want of Object.values(cases)) if (want) assert.ok(codes.has(want), want);
});

test('defaultTargetLang: the first preferred language decides, else zh-TW', () => {
  assert.equal(MS.FALLBACK_TARGET_LANG, 'zh-TW');
  assert.equal(MS.defaultTargetLang(['zh-Hant-TW', 'en-US']), 'zh-TW');
  assert.equal(MS.defaultTargetLang(['zh-Hans-CN']), 'zh-CN');
  assert.equal(MS.defaultTargetLang(['ja-JP', 'zh-TW']), 'ja');
  assert.equal(MS.defaultTargetLang(['ko-KR']), 'ko');
  assert.equal(MS.defaultTargetLang(['en-US', 'ja-JP']), 'en');
  // what Locale.preferredLanguages says on a Cantonese (Simplified) Mac,
  // where Safari reports zh-CN: both land on zh-CN
  assert.equal(MS.defaultTargetLang(['yue-Hans-CN']), 'zh-CN');
  assert.equal(MS.defaultTargetLang(['zh-CN']), 'zh-CN');
  // only the first: Safari's navigator.languages has just that one
  assert.equal(MS.defaultTargetLang(['fi-FI', 'ja-JP']), 'zh-TW');
  assert.equal(MS.defaultTargetLang('ja-JP'), 'ja');
  assert.equal(MS.defaultTargetLang([]), 'zh-TW');
  assert.equal(MS.defaultTargetLang(null), 'zh-TW');
  assert.equal(MS.defaultTargetLang(undefined), 'zh-TW');
});

// A fresh copy of shared.js under the given navigator (none when undefined),
// as a page or the popup would load it.
function loadShared(navigator) {
  const c = vm.createContext(navigator === undefined ? {} : { navigator });
  vm.runInContext(fs.readFileSync(EXT + '/shared.js', 'utf8'), c, { filename: 'shared.js' });
  return c.MS;
}

test('DEFAULT_SETTINGS.targetLang comes from navigator.languages', () => {
  const load = loadShared;
  assert.equal(load({ languages: ['ja-JP', 'en-US'], language: 'ja-JP' }).DEFAULT_SETTINGS.targetLang, 'ja');
  assert.equal(load({ languages: ['zh-HK'] }).DEFAULT_SETTINGS.targetLang, 'zh-TW');
  assert.equal(load({ languages: ['zh-CN'] }).DEFAULT_SETTINGS.targetLang, 'zh-CN');
  assert.equal(load({ language: 'ko-KR' }).DEFAULT_SETTINGS.targetLang, 'ko'); // no languages list
  assert.equal(load({ languages: ['fi-FI'] }).DEFAULT_SETTINGS.targetLang, 'zh-TW');
  assert.equal(load(undefined).DEFAULT_SETTINGS.targetLang, 'zh-TW');
  const ja = load({ languages: ['ja-JP'] });
  assert.equal(ja.mergeSettings(null).targetLang, 'ja');
  assert.equal(ja.mergeSettings(null).prefsUpdatedAt, 0);
  assert.equal(ja.mergeSettings({ targetLang: 'ko' }).targetLang, 'ko'); // a stored value stays
  // a navigator that throws doesn't stop shared.js from loading
  const c = vm.createContext({});
  Object.defineProperty(c, 'navigator', { get() { throw new Error('nope'); } });
  vm.runInContext(fs.readFileSync(EXT + '/shared.js', 'utf8'), c);
  assert.equal(c.MS.DEFAULT_SETTINGS.targetLang, 'zh-TW');
});

test('storedSettings: unchosen preferences stay out of storage, so the default keeps following the system', () => {
  const ja = loadShared({ languages: ['ja'] });
  const fresh = ja.mergeSettings(null);
  assert.equal(fresh.targetLang, 'ja');
  // A drag of the subtitles (or any display change) saves the whole object.
  const saved = j(ja.storedSettings(Object.assign({}, fresh, { bottomOffset: 22 })));
  for (const k of ['mode', 'targetLang', 'annotateLevel']) assert.ok(!(k in saved), k);
  assert.equal(saved.bottomOffset, 22);
  assert.equal(saved.prefsUpdatedAt, 0);
  assert.equal(saved.mergedMode, true);
  assert.equal(fresh.targetLang, 'ja'); // the argument is left alone
  // The system language changes to Traditional Chinese: so does the default.
  const tw = loadShared({ languages: ['zh-TW'] });
  const reread = tw.mergeSettings(saved);
  assert.equal(reread.targetLang, 'zh-TW');
  assert.equal(reread.mode, 'netflix');
  assert.equal(reread.bottomOffset, 22);
  assert.equal(reread.mergedMode, true); // a current object, not mistaken for a v1.0 one
  assert.equal(reread.prefsUpdatedAt, 0);
  // Stamped preferences are choices: stored as they are, whatever the system says later.
  const chosen = j(ja.storedSettings(Object.assign({}, fresh, { mode: 'translate', prefsUpdatedAt: 7 })));
  assert.deepEqual(j(MS.prefsOf(chosen)), { mode: 'translate', targetLang: 'ja', annotateLevel: 'B1', updatedAt: 7 });
  assert.equal(tw.mergeSettings(chosen).targetLang, 'ja');
  // A v1.0 object (no modes, no sync yet): its targetLang was the user's pick,
  // and stays through any number of saves, still unstamped, with its own mergedMode.
  const v1 = { enabled: true, targetLang: 'ko', fontScale: 1.2, bottomOffset: 10, styles: {}, mergedMode: false };
  let s = tw.mergeSettings(v1);
  for (let i = 0; i < 2; i++) {
    const stored = j(tw.storedSettings(Object.assign({}, s, { fontScale: 1 + i })));
    assert.equal(stored.targetLang, 'ko');
    assert.ok(!('mode' in stored));
    s = tw.mergeSettings(stored);
    assert.equal(s.targetLang, 'ko');
    assert.equal(s.mergedMode, false);
    assert.equal(s.prefsUpdatedAt, 0);
  }
});

const segs = (line, ann) => j(MS.matchAnnotations(line, ann));

test('matchAnnotations: no annotations / empty line', () => {
  assert.deepEqual(segs('Hello there.', []), [{ text: 'Hello there.' }]);
  assert.deepEqual(segs('Hello there.', null), [{ text: 'Hello there.' }]);
  assert.deepEqual(segs('', [{ term: 'x', gloss: 'y' }]), []);
});

test('matchAnnotations: Latin word boundaries ("keys" not inside "monkeys")', () => {
  assert.deepEqual(segs('The monkeys took the keys.', [{ term: 'keys', gloss: '鑰匙' }]),
    [{ text: 'The monkeys took the ' }, { text: 'keys', gloss: '鑰匙' }, { text: '.' }]);
  assert.deepEqual(segs('Look at those monkeys!', [{ term: 'keys', gloss: '鑰匙' }]),
    [{ text: 'Look at those monkeys!' }]);
  // case-insensitive, keeps the line's own casing
  assert.deepEqual(segs('Reluctant? Me?', [{ term: 'reluctant', gloss: '不情願' }]),
    [{ text: 'Reluctant', gloss: '不情願' }, { text: '? Me?' }]);
  // apostrophes and hyphens in terms
  assert.deepEqual(segs("It's a well-known fact.", [{ term: 'well-known', gloss: '眾所皆知' }]),
    [{ text: "It's a " }, { text: 'well-known', gloss: '眾所皆知' }, { text: ' fact.' }]);
  // accented letters count as word characters
  assert.deepEqual(segs('café cafés', [{ term: 'café', gloss: '咖啡館' }]),
    [{ text: 'café', gloss: '咖啡館' }, { text: ' cafés' }]);
  // regex metacharacters in a term are literal
  assert.deepEqual(segs('Is it (really) true?', [{ term: '(really)', gloss: '真的' }]),
    [{ text: 'Is it ' }, { text: '(really)', gloss: '真的' }, { text: ' true?' }]);
});

test('matchAnnotations: phrase "come up with", across a line break', () => {
  assert.deepEqual(segs('We need to come up with a plan.', [{ term: 'come up with', gloss: '想出' }]),
    [{ text: 'We need to ' }, { text: 'come up with', gloss: '想出' }, { text: ' a plan.' }]);
  assert.deepEqual(segs('We need to come up\nwith a plan.', [{ term: 'come up with', gloss: '想出' }]),
    [{ text: 'We need to ' }, { text: 'come up\nwith', gloss: '想出' }, { text: ' a plan.' }]);
  // longest wins at the same start
  assert.deepEqual(segs('Come up with something.', [{ term: 'come', gloss: '來' }, { term: 'come up with', gloss: '想出' }]),
    [{ text: 'Come up with', gloss: '想出' }, { text: ' something.' }]);
});

test('matchAnnotations: CJK substring', () => {
  assert.deepEqual(segs('我們得想個辦法。', [{ term: '辦法', gloss: 'solution' }]),
    [{ text: '我們得想個' }, { text: '辦法', gloss: 'solution' }, { text: '。' }]);
  assert.deepEqual(segs('彼は諦めなかった。', [{ term: '諦め', gloss: '放棄' }]),
    [{ text: '彼は' }, { text: '諦め', gloss: '放棄' }, { text: 'なかった。' }]);
  // a Latin edge next to CJK text is still a boundary
  assert.deepEqual(segs('我買了T恤', [{ term: 'T恤', gloss: 'T-shirt' }]),
    [{ text: '我買了' }, { text: 'T恤', gloss: 'T-shirt' }]);
});

test('matchAnnotations: first occurrence, duplicates, overlaps left to right', () => {
  assert.deepEqual(segs('run, run, run', [{ term: 'run', gloss: '跑' }]),
    [{ text: 'run', gloss: '跑' }, { text: ', run, run' }]);
  assert.deepEqual(segs('run, run', [{ term: 'run', gloss: '跑' }, { term: 'Run', gloss: '奔' }]),
    [{ text: 'run', gloss: '跑' }, { text: ', run' }]);
  // overlapping: "give up on" (starts first) beats "up on"
  assert.deepEqual(segs("Don't give up on me", [{ term: 'up on', gloss: 'X' }, { term: 'give up on', gloss: '放棄' }]),
    [{ text: "Don't " }, { text: 'give up on', gloss: '放棄' }, { text: ' me' }]);
  // overlapping: the earlier match wins even if shorter
  assert.deepEqual(segs('break down the door', [{ term: 'down the door', gloss: 'Y' }, { term: 'break down', gloss: '撞開' }]),
    [{ text: 'break down', gloss: '撞開' }, { text: ' the door' }]);
  // non-overlapping matches both render, in line order
  assert.deepEqual(segs('a reluctant hero, quite adamant', [{ term: 'adamant', gloss: '堅決' }, { term: 'reluctant', gloss: '不情願' }]),
    [{ text: 'a ' }, { text: 'reluctant', gloss: '不情願' }, { text: ' hero, quite ' }, { text: 'adamant', gloss: '堅決' }]);
  // invalid items are ignored
  assert.deepEqual(segs('hello world', [{ term: 'world' }, { term: '', gloss: 'x' }, null, { term: 'hello', gloss: '  ' }]),
    [{ text: 'hello world' }]);
  // terms that don't occur are dropped
  assert.deepEqual(segs('hello world', [{ term: 'planet', gloss: '行星' }]), [{ text: 'hello world' }]);
});

test('findCueIndex / cueIndexAtOrAfter: an earlier, longer cue stays on screen around a shorter one', () => {
  // A 10-20 (a sign), B 12-14 inside it, C 25-27
  const cues = [{ start: 10, end: 20 }, { start: 12, end: 14 }, { start: 25, end: 27 }];
  assert.equal(MS.findCueIndex(cues, 11), 0);
  assert.equal(MS.findCueIndex(cues, 13), 1); // the one that started last wins
  assert.equal(MS.findCueIndex(cues, 14.1), 1); // still bridged
  assert.equal(MS.findCueIndex(cues, 15), 0); // A comes back instead of blank
  assert.equal(MS.findCueIndex(cues, 19), 0);
  assert.equal(MS.findCueIndex(cues, 20.1), 0);
  assert.equal(MS.findCueIndex(cues, 21), -1);
  assert.equal(MS.findCueIndex(cues, 26), 2);
  assert.equal(MS.cueIndexAtOrAfter(cues, 15), 0); // A, not C
  assert.equal(MS.cueIndexAtOrAfter(cues, 13), 1);
  assert.equal(MS.cueIndexAtOrAfter(cues, 22), 2);
  assert.equal(MS.cueIndexAtOrAfter(cues, 5), 0);
  // the backwards scan stops at the first cue whose run of ends can't reach t
  const many = [{ start: 0, end: 100 }].concat(Array.from({ length: 50 }, (_, i) => ({ start: 1 + i * 2, end: 2 + i * 2 })));
  assert.equal(MS.findCueIndex(many, 50.5), 0);
  assert.equal(MS.findCueIndex(many, 51.5), 26);
  assert.equal(MS.findCueIndex(many, 101), -1);
  // a fresh (replaced) array is not served from the cache of the old one
  const a = [{ start: 0, end: 1 }, { start: 2, end: 3 }];
  assert.equal(MS.findCueIndex(a, 2.5), 1);
  assert.equal(MS.findCueIndex([{ start: 0, end: 10 }, { start: 2, end: 3 }], 5), 0);
});

// Mirrors Prompts.termOccurs in Shared/Prompts.swift (normalizeForMatch +
// usesSpacedScript + the boundary regex), case by case.
const occurs = (line, term) => MS.findTerm(line, term) != null;
test('findTerm parity with Swift termOccurs', () => {
  // curly apostrophes, either side
  assert.ok(occurs('I can’t stand him.', "can't stand"));
  assert.ok(occurs("I can't stand him.", 'can’t stand'));
  assert.ok(occurs('‘Tis the season', "'tis"));
  assert.deepEqual(j(MS.findTerm('I can’t stand him.', "can't stand")), [2, 13]); // offsets into the original line
  // Latin/Greek/Cyrillic: word boundaries on letters, marks and digits of any script
  assert.ok(!occurs('The monkeys took it', 'keys'));
  assert.ok(!occurs('start', 'art'));
  assert.ok(occurs('art, start', 'art'));
  assert.ok(!occurs('我喜歡OK嗎', 'OK')); // a Han letter next to a Latin term is no boundary in Swift
  assert.ok(!occurs('version2', 'version'));
  assert.ok(occurs('Привет, мир', 'мир'));
  assert.ok(!occurs('мирный', 'мир'));
  assert.ok(occurs('ΚΑΛΗΜΕΡΑ κόσμε', 'καλημερα'));
  // spaces in a spaced-script term match any whitespace run, incl. line breaks
  assert.ok(occurs('come  up\nwith', 'come up with'));
  // other scripts: plain substring, no boundary check (Arabic prefix و, Hebrew ה)
  assert.ok(occurs('والكتاب على الطاولة', 'الكتاب'));
  assert.ok(occurs('הספר על השולחן', 'ספר'));
  assert.ok(occurs('彼は諦めなかった', '諦め'));
  assert.ok(occurs('我買了T恤', 'T恤')); // mixed term: not all-Latin, so substring
  assert.ok(occurs('커피를 마셨다', '커피'));
  // ...but no whitespace flexibility there (Swift matches the literal string)
  assert.ok(!occurs('東京  タワー', '東京 タワー'));
  assert.ok(occurs('東京\nタワー', '東京 タワー')); // line breaks are normalized to a space
  // case-insensitive both ways; empty term never matches
  assert.ok(occurs('RELUCTANT hero', 'reluctant'));
  assert.ok(!occurs('anything', '   '));
});

console.log('\n' + passed + ' tests passed' + (process.exitCode ? ', some FAILED' : ''));

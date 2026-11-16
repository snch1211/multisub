'use strict';
// Runs the extension in WebKit, the engine Safari uses, through
// tests/webkit/.build/harness (see README.md here):
//  - smoke in three system languages, and an old-style manifest
//    (background.scripts) that must break in zh-Hant the way it broke in
//    Safari;
//  - the watch scenarios in fixtures/scenarios on the mock Netflix page,
//    over https (data: URL fixtures), one again in ja, one over http
//    (loopback server), one with the manifest read through JSON.parse;
//  - the extension reloaded under the open tab, over a build whose content
//    script doesn't step aside (as the versions already shipped don't), and
//    the other way round, onto such a build;
//  - copies of the extension with a known mistake (no cue text cleanup, none
//    for TTML, a forced-narrative second line, no world: "MAIN" inject.js, a
//    content script that doesn't announce itself, no stylesheet marker) that
//    must fail.
// Skips (exit 0) when not on macOS or when the harness doesn't build.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const assert = require('assert/strict');

const HERE = __dirname;
const EXT = process.env.EXT || path.resolve(HERE, '../../extension');
const HARNESS = path.join(HERE, '.build', 'harness');
const SCENARIOS = path.join(HERE, 'fixtures', 'scenarios');
const SNAPSHOTS = path.join(HERE, '.build', 'snapshots');

function skip(why) {
  console.log('skipped: ' + why);
  process.exit(0);
}

if (process.platform !== 'darwin') skip('the WebKit harness needs macOS');
const build = spawnSync(path.join(HERE, 'build.sh'), [], { encoding: 'utf8' });
if (build.status !== 0 || !fs.existsSync(HARNESS)) {
  skip('the WebKit harness did not build (macOS 15.4+ and Xcode or the Command Line Tools are needed)\n' +
    String(build.stderr || build.error || '').trim().split('\n').slice(-8).join('\n'));
}

// Runs the harness and returns { status, result, stderr }; result is the
// parsed RESULT line.
function harness(args, timeoutMs = 120000) {
  const r = spawnSync(HARNESS, args, { encoding: 'utf8', timeout: timeoutMs });
  const line = String(r.stdout || '').split('\n').find((l) => l.startsWith('RESULT '));
  let result = null;
  try { result = line ? JSON.parse(line.slice(7)) : null; } catch (e) { /* reported below */ }
  return { status: r.status, signal: r.signal, result, stderr: String(r.stderr || '') };
}

const failedChecks = (res) => ((res.result && res.result.checks) || []).filter((c) => !c.ok);
const describe = (res) => {
  const lines = failedChecks(res).map((c) => c.name + (c.detail !== undefined ? ': ' + JSON.stringify(c.detail) : ''));
  if (res.result && res.result.error) lines.push('error: ' + res.result.error);
  if (res.signal) lines.push('killed by ' + res.signal);
  return lines.join('\n') || res.stderr.split('\n').slice(-6).join('\n');
};

function assertPassed(res) {
  assert.ok(res.result, 'no RESULT line (exit ' + res.status + ')\n' + res.stderr.slice(-800));
  assert.equal(res.status, 0, describe(res));
  assert.equal(res.result.ok, true);
}

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('ok   ' + name); }
  catch (e) { console.log('FAIL ' + name + '\n     ' + String(e.message || e).split('\n').slice(0, 12).join('\n     ')); process.exitCode = 1; }
}

const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'mswebkit-'));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));

// A copy of a scenario from fixtures/scenarios with some fields replaced
// (undefined drops one), written to tmp with an absolute fixture dir.
function scenarioVariant(file, tag, changes) {
  const scenario = Object.assign(JSON.parse(fs.readFileSync(path.join(SCENARIOS, file), 'utf8')),
    { fixtures: path.join(HERE, 'fixtures') }, changes);
  const out = path.join(tmp, path.basename(file, '.json') + '-' + tag + '.json');
  fs.writeFileSync(out, JSON.stringify(scenario));
  return out;
}

// A copy of the extension in tmp, changed by edit(dir).
function extensionVariant(tag, edit) {
  const dir = path.join(tmp, tag);
  fs.cpSync(EXT, dir, { recursive: true });
  edit(dir);
  return dir;
}

function assertFailedWith(res, checkName) {
  assert.ok(res.result, 'no RESULT line (exit ' + res.status + ')\n' + res.stderr.slice(-800));
  assert.equal(res.status, 1, 'expected the checks to fail\n' + describe(res));
  const failed = failedChecks(res);
  const hit = failed.find((c) => c.name === checkName);
  assert.ok(hit, 'expected "' + checkName + '" to fail; failed: ' + (failed.map((c) => c.name).join(', ') || 'none'));
  return hit;
}

// --- smoke ------------------------------------------------------------------

const LANGUAGES = { 'zh-Hant': 'Big5', ja: 'Shift_JIS', en: 'windows-1252' };
for (const [lang, encoding] of Object.entries(LANGUAGES)) {
  test(`smoke in ${lang} (legacy encoding ${encoding}): background, popup and ping all work`, () => {
    const res = harness(['smoke', EXT, '-AppleLanguages', `(${lang})`]);
    assertPassed(res);
    assert.equal(res.result.legacyEncoding, encoding, 'the harness did not switch the system language');
    assert.equal(res.result.popup.charset, 'UTF-8');
    assert.equal(res.result.popup.ping.ok, true);
  });
}

// The manifest form that broke in Safari: "background.scripts" makes WebKit
// generate the background page without a charset. `edit(dir)`, if given,
// changes the copy further.
function oldManifestCopy(tag, edit) {
  const dir = path.join(tmp, tag);
  fs.cpSync(EXT, dir, { recursive: true });
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
  const page = manifest.background && manifest.background.page;
  assert.ok(page, 'manifest.json has no background.page any more; update this test');
  const html = fs.readFileSync(path.join(dir, page), 'utf8');
  const scripts = Array.from(html.matchAll(/<script[^>]*\bsrc="([^"]+)"/g), (m) => m[1]);
  assert.ok(scripts.length, 'no <script src> in ' + page);
  manifest.background = { scripts, persistent: manifest.background.persistent };
  fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2));
  fs.rmSync(path.join(dir, page));
  if (edit) edit(dir);
  return dir;
}

// shared.js as it was then: its curly apostrophes written as they are in a
// regular expression, where Big5 makes the second one swallow the "]".
function literalApostrophes(dir) {
  const file = path.join(dir, 'shared.js');
  const src = fs.readFileSync(file, 'utf8');
  const patched = src.replace('/[\\u2018\\u2019]/g', '/[\u2018\u2019]/g');
  assert.notEqual(patched, src, 'shared.js has no /[\\u2018\\u2019]/g any more; update this test');
  fs.writeFileSync(file, patched);
}

test('old manifest (background.scripts) with shared.js as it was fails in zh-Hant: decoded as Big5, ping never reaches native', () => {
  const dir = oldManifestCopy('old-manifest', literalApostrophes);
  const res = harness(['smoke', dir, '-AppleLanguages', '(zh-Hant)']);
  assert.ok(res.result, 'no RESULT line\n' + res.stderr.slice(-800));
  assert.equal(res.status, 1, 'expected the checks to fail\n' + res.stderr.slice(-800));
  const failed = failedChecks(res).map((c) => c.name);
  assert.ok(failed.includes('ping-native round trip (popup -> background -> native)'), 'failed: ' + failed.join(', '));
  const ping = res.result.popup && res.result.popup.ping;
  assert.equal(ping && ping.error, 'native-unavailable');
  assert.match(ping.detail, /shared\.js did not load/);
  // Same mistake in the other languages, for the record.
  for (const lang of ['ja', 'en']) {
    const other = harness(['smoke', dir, '-AppleLanguages', `(${lang})`]);
    console.log(`     (${lang}: ${other.status === 0 ? 'passes' : 'fails: ' + failedChecks(other).map((c) => c.name).join(', ')})`);
  }
});

// The \u escapes in shared.js's regular expressions are the second line of
// defence: with the old manifest the background page is still not UTF-8
// (Chinese text comes out garbled), but the scripts parse and the ping gets
// through.
test('old manifest in zh-Hant with shared.js as it is now: still not UTF-8, but the ping gets through', () => {
  const dir = oldManifestCopy('old-manifest-escaped');
  const res = harness(['smoke', dir, '-AppleLanguages', '(zh-Hant)']);
  assert.ok(res.result, 'no RESULT line\n' + res.stderr.slice(-800));
  const failed = failedChecks(res).map((c) => c.name);
  assert.ok(!failed.includes('ping-native round trip (popup -> background -> native)'), describe(res));
  assert.equal(res.result.popup.ping.ok, true);
  if (res.result.background && typeof res.result.background === 'object') {
    assert.ok(failed.includes('background page is decoded as UTF-8'), 'failed: ' + failed.join(', '));
    assert.equal(res.result.background.ms, 'object', 'shared.js did not load in the background page');
  }
});

// --- watch ------------------------------------------------------------------

fs.mkdirSync(SNAPSHOTS, { recursive: true });
const scenarios = fs.readdirSync(SCENARIOS).filter((f) => f.endsWith('.json')).sort();
assert.ok(scenarios.length, 'no scenarios in ' + SCENARIOS);

for (const file of scenarios) {
  const name = path.basename(file, '.json');
  const scenario = JSON.parse(fs.readFileSync(path.join(SCENARIOS, file), 'utf8'));
  test(`watch ${name}: ${scenario.name}`, () => {
    const snapshot = path.join(SNAPSHOTS, name + '.png');
    const res = harness(['watch', EXT, path.join(SCENARIOS, file), '--snapshot', snapshot]);
    assertPassed(res);
    assert.ok(fs.existsSync(snapshot), 'no snapshot');
  });
}

test('watch engine-error in ja: the content scripts\' Chinese text survives a Shift_JIS default', () => {
  const res = harness(['watch', EXT, path.join(SCENARIOS, 'engine-error.json'), '-AppleLanguages', '(ja)']);
  assertPassed(res);
  assert.equal(res.result.language, 'ja');
});

test('watch translate over http: fixtures from the loopback server (CORS, byte ranges)', () => {
  const res = harness(['watch', EXT, path.join(SCENARIOS, 'translate.json'), '--scheme', 'http']);
  assertPassed(res);
  const requests = res.result.serverRequests || [];
  assert.ok(requests.includes('POST /manifest'), requests.join(', '));
  assert.ok(requests.includes('GET /subs/en.vtt'), requests.join(', '));
  assert.ok(requests.includes('GET /subs/zh-Hant.dfxp'), requests.join(', '));
  if (res.result.video === 'media file') {
    assert.ok(requests.includes('GET /video.mp4'), requests.join(', '));
    assert.ok(res.result.serverRangeRequests > 0, 'the video was not loaded with byte ranges');
  }
});

// The scenarios above read the manifest with Response.json(); inject.js
// hooks JSON.parse too, and Netflix has used both.
test('watch translate with the manifest read through JSON.parse (inject.js\'s other capture hook)', () => {
  const res = harness(['watch', EXT, scenarioVariant('translate.json', 'parse', { manifestVia: 'parse' })]);
  assertPassed(res);
  const events = res.result.page.events || [];
  assert.ok(events.includes('manifest: loaded via JSON.parse'), 'the page did not use JSON.parse: ' + events.join(', '));
});

// Copies of the extension with a known mistake, to prove the watch checks
// catch it.

// Without inject.js's cleanup, Netflix's "&lrm;" reaches the overlay as
// text.
test('watch fails when inject.js stops cleaning cue text (&lrm; on screen)', () => {
  const dir = extensionVariant('no-clean', (d) => {
    const file = path.join(d, 'inject.js');
    const src = fs.readFileSync(file, 'utf8');
    const patched = src.replace(/function cleanText\(s\) \{/, 'function cleanText(s) { return s;');
    assert.notEqual(patched, src, 'inject.js has no cleanText(s) any more; update this test');
    fs.writeFileSync(file, patched);
  });
  const scenario = path.join(tmp, 'lrm.json');
  fs.writeFileSync(scenario, JSON.stringify({
    name: 'entity leak', fixtures: path.join(HERE, 'fixtures'),
    settings: { enabled: true, mode: 'netflix', targetLang: 'zh-TW', mergedMode: true, prefsUpdatedAt: 1 },
    checkpoints: [{ time: 2, waitMs: 8000, expect: { original: 'Welcome back to the laboratory.' } }]
  }));
  const res = harness(['watch', dir, scenario]);
  assert.equal(res.status, 1, 'expected the checks to fail\n' + describe(res));
  const leak = failedChecks(res).find((c) => /no literal entities/.test(c.name));
  assert.ok(leak, 'no entity-leak failure: ' + describe(res));
  assert.deepEqual(leak.detail, ['&lrm;']);
});

// Netflix's Chinese tracks come as TTML, whose direction marks
// (fixtures/zh-Hant.dfxp: "&amp;lrm;" at 13-16 s, "&#8206;" at 17-20 s) must
// get the same cleanup as WebVTT's: on screen in netflix mode, and in the
// reference lines translate sends to the AI.
test('watch fails when inject.js\'s TTML parser skips the cleanup (&lrm; and U+200E on the second line and in the prompts)', () => {
  const dir = extensionVariant('ttml-raw', (d) => {
    const file = path.join(d, 'inject.js');
    const src = fs.readFileSync(file, 'utf8');
    const patched = src.replace("t = cleanText(t.replace(/\\s*\\n\\s*/g, '\\n'));", "t = t.replace(/\\s*\\n\\s*/g, '\\n').trim();");
    assert.notEqual(patched, src, 'inject.js\'s parseTTML no longer calls cleanText that way; update this test');
    fs.writeFileSync(file, patched);
  });
  const netflix = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'netflix.json'), 'utf8'));
  const marked = netflix.checkpoints.filter((cp) => cp.time === 14 || cp.time === 18);
  assert.equal(marked.length, 2, 'netflix.json has no checkpoints at 14 and 18 s any more; update this test');
  const res = harness(['watch', dir, scenarioVariant('netflix.json', 'ttml-raw', { checkpoints: marked, status: undefined })]);
  assert.deepEqual(assertFailedWith(res, 'no literal entities on the page at 14.0 s').detail, ['&lrm;']);
  assert.match(assertFailedWith(res, 'overlay at 18.0 s').detail, /\u200E/);
  const translate = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'translate.json'), 'utf8'));
  const res2 = harness(['watch', dir, scenarioVariant('translate.json', 'ttml-raw', { checkpoints: translate.checkpoints.slice(0, 1) })]);
  const leaks = assertFailedWith(res2, 'no direction marks or entities in subtitle text sent to native').detail;
  assert.ok(leaks.some((l) => l.includes('&lrm;')) && leaks.some((l) => l.includes('<U+200E>')), JSON.stringify(leaks));
});

// fixtures/manifest.json lists the forced-narrative zh-Hant track before the
// full one, so a second-line choice that stops skipping forced tracks picks
// it and shows its one cue (17-20 s) instead of the full track's.
test('watch netflix fails when content.js picks the forced-narrative track for the second line', () => {
  const dir = extensionVariant('forced-second', (d) => {
    const file = path.join(d, 'content.js');
    const src = fs.readFileSync(file, 'utf8');
    const patched = src.replace(/(function chooseSecondTrack\([^)]*\) \{[^}]*?)!t\.forced &&\s*/, '$1');
    assert.notEqual(patched, src, 'content.js chooseSecondTrack has no "!t.forced &&" any more; update this test');
    fs.writeFileSync(file, patched);
  });
  const scenario = scenarioVariant('netflix.json', 'forced', {
    checkpoints: [{ time: 18, waitMs: 8000, expect: { original: "Don't touch anything.", text: '什麼都別碰。' } }],
    status: undefined, native: undefined
  });
  const res = harness(['watch', dir, scenario]);
  assertFailedWith(res, 'overlay at 18.0 s');
  assert.equal(res.result.checkpoints[0].observed.text, '［標誌：禁止進入］', 'not the forced track\'s cue');
});

// Without the world: "MAIN" entry, content.js's <script src> fallback still
// runs inject.js, so the overlay works on the mock page, but only after the
// page's own scripts: on Netflix the player can parse its manifest first.
test('watch fails when inject.js is no longer a world: "MAIN" content script (fallback only)', () => {
  const dir = extensionVariant('no-main-world', (d) => {
    const file = path.join(d, 'manifest.json');
    const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
    const scripts = manifest.content_scripts || [];
    const kept = scripts.filter((cs) => cs.world !== 'MAIN');
    assert.equal(kept.length, scripts.length - 1, 'manifest.json has no world: "MAIN" content script; update this test');
    manifest.content_scripts = kept;
    fs.writeFileSync(file, JSON.stringify(manifest, null, 2));
  });
  const translate = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'translate.json'), 'utf8'));
  const scenario = scenarioVariant('translate.json', 'no-main', { checkpoints: translate.checkpoints.slice(0, 1) });
  const res = harness(['watch', dir, scenario]);
  assertFailedWith(res, 'inject.js hooked JSON.parse before the page\'s scripts (world MAIN)');
  assert.equal(res.result.page.injected, true, 'the <script src> fallback did not run inject.js either');
});

// --- the extension reloaded under an open tab --------------------------------

// content.js patched so that it neither steps aside nor marks or hides
// anything, and sets html.multisub-native-hidden only when its own idea of
// it changes (starting from "not hidden"), like the versions shipped before
// instances knew of each other.
function uncooperative(src) {
  const patches = [
    [/function announce\(\) \{/, 'function announce() { return;'],
    [/function teardown\(reason, by\) \{/, 'function teardown(reason, by) { return;'],
    [/function keepInstanceStyle\(\) \{/, 'function keepInstanceStyle() { return;'],
    [/function removeForeignElements\(\) \{/, 'function removeForeignElements() { return;'],
    [/overlay\.setAttribute\(INSTANCE_ATTR, INSTANCE_ID\);/, ''],
    [/if \(classes\.contains\('multisub-native-hidden'\) !== hide\) (classes\.toggle\('multisub-native-hidden', hide\);)/,
      'if (hide === !!state.shippedNativeHidden) return; state.shippedNativeHidden = hide; $1']
  ];
  for (const [re, to] of patches) {
    const next = src.replace(re, to);
    assert.notEqual(next, src, 'content.js has no ' + re + ' any more; update this test');
    src = next;
  }
  return src;
}

// overlay.css without the --multisub-stylesheet marker in extension copy `dir`.
function withoutMarker(dir) {
  const file = path.join(dir, 'overlay.css');
  const src = fs.readFileSync(file, 'utf8');
  const patched = src.replace(/--multisub-stylesheet:\s*1;/, '');
  assert.notEqual(patched, src, 'overlay.css has no --multisub-stylesheet marker any more; update this test');
  fs.writeFileSync(file, patched);
}

// A build from before instances knew of each other: uncooperative()'s
// content.js and an overlay.css without the marker.
function shippedLikeBuild(tag) {
  return extensionVariant(tag, (d) => {
    const file = path.join(d, 'content.js');
    fs.writeFileSync(file, uncooperative(fs.readFileSync(file, 'utf8')));
    withoutMarker(d);
  });
}

// What Safari did to a viewer: a new build installed while Netflix was open
// left the old content script drawing its own overlay under the new one's.
test('watch reload over a build that doesn\'t step aside: its overlay is hidden, the new one draws alone', () => {
  const old = shippedLikeBuild('uncooperative');
  const reload = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'reload.json'), 'utf8'));
  const [first, second] = reload.checkpoints;
  const scenario = scenarioVariant('reload.json', 'over-old', {
    checkpoints: [first, Object.assign({}, second, { extension: EXT,
      expect: Object.assign({}, second.expect, { overlaysInDOM: 2 }) })]
  });
  const res = harness(['watch', old, scenario]);
  assertPassed(res);
});

// The other way round, as when switching between builds: an older build is
// installed while this one runs. It never says hello, so this instance sees
// its stylesheet go and steps aside as if the extension were off. Netflix's
// own line must stay hidden under the older build's overlay: that build set
// the class when its cues came, and sets it again only when its own idea of
// it changes.
test('watch reload onto a build from before instances: it draws alone and Netflix\'s own line stays hidden', () => {
  const older = shippedLikeBuild('shipped-onto');
  const reload = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'reload.json'), 'utf8'));
  const netflix = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'netflix.json'), 'utf8'));
  const linesAt = (time) => {
    const cp = netflix.checkpoints.find((c) => c.time === time);
    assert.ok(cp, 'netflix.json has no checkpoint at ' + time + ' s any more; update this test');
    return { original: cp.expect.original, text: cp.expect.text };
  };
  const alone = { overlays: 1, overlaysInDOM: 1, nativeHidden: true, nativeVisible: false };
  const checkpoints = [reload.checkpoints[0],
    { time: 6, action: 'reload-extension', extension: older, waitMs: 8000, expect: Object.assign(linesAt(6), alone) },
    { time: 14, waitMs: 4000, expect: Object.assign(linesAt(14), alone) },
    { time: 18, waitMs: 4000, expect: Object.assign(linesAt(18), alone) }];
  const res = harness(['watch', EXT, scenarioVariant('reload.json', 'onto-shipped', { checkpoints, native: undefined })]);
  assertPassed(res);
});

test('watch reload fails when content.js doesn\'t announce itself (the old instance keeps going)', () => {
  const dir = extensionVariant('no-hello', (d) => {
    const file = path.join(d, 'content.js');
    const src = fs.readFileSync(file, 'utf8');
    const patched = src.replace(/function announce\(\) \{/, 'function announce() { return;');
    assert.notEqual(patched, src, 'content.js has no announce() any more; update this test');
    fs.writeFileSync(file, patched);
  });
  const reload = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'reload.json'), 'utf8'));
  const res = harness(['watch', dir, scenarioVariant('reload.json', 'no-hello', { checkpoints: reload.checkpoints.slice(0, 2) })]);
  // Two overlays on the page, or two instances taking each other's off and
  // hiding each other's: never just the new one.
  const hit = assertFailedWith(res, 'overlay at 6.0 s');
  assert.match(hit.detail, /overlays(InDOM)?: want \[1\] got \[[02]\]/);
});

test('watch fails when overlay.css has no marker (a turned-off extension keeps drawing)', () => {
  const dir = extensionVariant('no-marker', withoutMarker);
  const reload = JSON.parse(fs.readFileSync(path.join(SCENARIOS, 'reload.json'), 'utf8'));
  const [first, , off] = reload.checkpoints;
  const res = harness(['watch', dir, scenarioVariant('reload.json', 'no-marker', { checkpoints: [first, off], native: undefined })]);
  const hit = assertFailedWith(res, 'overlay at 10.0 s');
  assert.match(hit.detail, /nativeHidden: want \[false\] got \[true\]/);
});

console.log('\n' + passed + ' tests passed' + (process.exitCode ? ', some FAILED' : '') + '  (snapshots: ' + path.relative(process.cwd(), SNAPSHOTS) + ')');

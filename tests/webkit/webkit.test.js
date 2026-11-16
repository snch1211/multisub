'use strict';
// Runs the extension in WebKit, the engine Safari uses, through
// tests/webkit/.build/harness (see README.md here):
//  - smoke in three system languages, and an old-style manifest
//    (background.scripts) that must break in zh-Hant the way it broke in
//    Safari;
//  - the watch scenarios in fixtures/scenarios on the mock Netflix page,
//    over https (data: URL fixtures), one again in ja, one over http
//    (loopback server), one with the manifest read through JSON.parse;
//  - copies of the extension with a known mistake (no entity decoding, a
//    forced-narrative second line, no world: "MAIN" inject.js) that must
//    fail.
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
// generate the background page without a charset.
function oldManifestCopy() {
  const dir = path.join(tmp, 'old-manifest');
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
  return dir;
}

test('old manifest (background.scripts) fails in zh-Hant: shared.js decoded as Big5, ping never reaches native', () => {
  const dir = oldManifestCopy();
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

// Without entity decoding in inject.js, Netflix's "&lrm;" reaches the
// overlay as text.
test('watch fails when inject.js stops decoding entities (&lrm; on screen)', () => {
  const dir = extensionVariant('no-decode', (d) => {
    const file = path.join(d, 'inject.js');
    const src = fs.readFileSync(file, 'utf8');
    const patched = src.replace(/function decodeEntities\(s\) \{/, 'function decodeEntities(s) { return s;');
    assert.notEqual(patched, src, 'inject.js has no decodeEntities(s) any more; update this test');
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

console.log('\n' + passed + ' tests passed' + (process.exitCode ? ', some FAILED' : '') + '  (snapshots: ' + path.relative(process.cwd(), SNAPSHOTS) + ')');

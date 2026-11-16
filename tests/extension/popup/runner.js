'use strict';
// Runs one popup scenario: the real popup (extension/popup.html + popup.js +
// shared.js) with the scripted browser API (mock.js) and the scenario driver
// (driver.js), loaded as a local page in one of two engines:
//
//   webkit  tests/webkit/.build/harness page <file>: a plain WKWebView, the
//           engine Safari uses. Build it with tests/webkit/build.sh.
//   chrome  headless Google Chrome with --dump-dom.
//
// MULTISUB_POPUP_ENGINE=webkit|chrome picks one; by default it's webkit when
// the harness is built, else chrome.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const HERE = __dirname;
const HARNESS = path.resolve(__dirname, '../../webkit/.build/harness');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

function engine() {
  const env = process.env.MULTISUB_POPUP_ENGINE;
  if (env === 'webkit' || env === 'chrome') return env;
  if (env) throw new Error('MULTISUB_POPUP_ENGINE must be webkit or chrome, not ' + JSON.stringify(env));
  return process.platform === 'darwin' && fs.existsSync(HARNESS) ? 'webkit' : 'chrome';
}

// Copies the popup and the test scripts into a temp dir and returns the
// popup's file URL with the scenario config in the hash.
function stage(dir, ext, cfg) {
  for (const f of ['popup.css', 'popup.js', 'shared.js']) fs.copyFileSync(path.join(ext, f), path.join(dir, f));
  fs.copyFileSync(path.join(HERE, 'mock.js'), path.join(dir, 'mock.js'));
  fs.copyFileSync(path.join(HERE, 'driver.js'), path.join(dir, 'driver.js'));
  const html = fs.readFileSync(path.join(ext, 'popup.html'), 'utf8')
    .replace('<script src="shared.js"></script>', '<script src="mock.js"></script><script src="shared.js"></script>')
    .replace('<script src="popup.js"></script>', '<script src="popup.js"></script><script src="driver.js"></script>');
  fs.writeFileSync(path.join(dir, 'popup.html'), html);
  return 'file://' + dir + '/popup.html#' + encodeURIComponent(JSON.stringify(cfg));
}

// Returns the raw JSON text the driver wrote between @@OUT@@ and @@END@@.
function runWebKit(url) {
  try {
    return execFileSync(HARNESS, ['page', url, '--timeout', '40'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 }).trim();
  } catch (e) {
    throw new Error('WebKit page run failed (' + (e.status != null ? 'exit ' + e.status : e.message) + ')\n' + String(e.stderr || '').trim());
  }
}

function runChrome(url, dir) {
  const out = execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--user-data-dir=' + path.join(dir, 'prof'),
    '--virtual-time-budget=20000', '--dump-dom', url], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 60000 });
  const m = out.match(/@@OUT@@([\s\S]*?)@@END@@/);
  if (!m) throw new Error('no result in dumped DOM');
  // --dump-dom serializes the DOM, so the text comes back HTML-escaped.
  return m[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
}

// Runs one scenario and returns the driver's result object; throws when the
// scenario itself failed.
function run(cfg, opts) {
  const ext = (opts && opts.ext) || path.resolve(__dirname, '../../../extension');
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'mspopup-'));
  let raw;
  try {
    const url = stage(dir, ext, cfg);
    raw = engine() === 'webkit' ? runWebKit(url) : runChrome(url, dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  const res = JSON.parse(raw);
  if (!res.ok) throw new Error(res.error + ' log=' + JSON.stringify(res.log));
  return res.result;
}

module.exports = { run, engine, HARNESS };

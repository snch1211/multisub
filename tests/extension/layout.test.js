'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const EXT = process.env.EXT || path.resolve(__dirname, '../../extension');

const manifest = JSON.parse(fs.readFileSync(EXT + '/manifest.json', 'utf8'));
assert.equal(manifest.version, '1.2.0');
// The background must be an HTML page that pins UTF-8: with background.scripts
// Safari decodes the scripts in the system's legacy encoding (Big5, GBK,
// Shift_JIS…) and shared.js stops parsing.
assert.deepEqual(manifest.background, { page: 'background.html', persistent: false });
const bgHtml = fs.readFileSync(EXT + '/background.html', 'utf8');
assert.match(bgHtml.slice(0, 200), /<meta charset="utf-8">/i, 'background.html declares UTF-8 before anything else');
const bgScripts = [...bgHtml.matchAll(/<script\s+src="([^"]+)"/g)].map((m) => m[1]);
assert.deepEqual(bgScripts, ['shared.js', 'background.js']);
const popupHead = fs.readFileSync(EXT + '/popup.html', 'utf8').slice(0, 200);
assert.match(popupHead, /<meta charset="utf-8">/i, 'popup.html declares UTF-8');
const [main, page] = manifest.content_scripts;
assert.deepEqual(main.js, ['shared.js', 'content.js']);
assert.deepEqual(main.css, ['overlay.css']);
assert.deepEqual(page, { matches: ['*://*.netflix.com/*'], js: ['inject.js'], run_at: 'document_start', world: 'MAIN' });
const referenced = new Set([manifest.background.page, ...bgScripts, ...main.js, ...main.css, ...page.js,
  manifest.action.default_popup, ...manifest.web_accessible_resources[0].resources]);
for (const f of referenced) assert.ok(fs.existsSync(path.join(EXT, f)), 'missing ' + f);
console.log('ok   manifest: order and files');

const html = fs.readFileSync(EXT + '/popup.html', 'utf8');
const scripts = [...html.matchAll(/<script\s+src="([^"]+)"/g)].map((m) => m[1]);
assert.deepEqual(scripts, ['shared.js', 'popup.js']);
assert.ok(html.indexOf('popup.css') > 0);
assert.ok(!/https?:\/\//.test(html.replace(/http:\/\/localhost:1234\/v1/, '')), 'no external resources');
// Every id popup.js looks up exists in popup.html, once.
const js = fs.readFileSync(EXT + '/popup.js', 'utf8');
const ids = new Set([...js.matchAll(/\$\('([A-Za-z]+)'\)/g)].map((m) => m[1]));
for (const id of ids) {
  const n = (html.match(new RegExp('id="' + id + '"', 'g')) || []).length;
  assert.equal(n, 1, 'id ' + id + ' appears ' + n + ' times in popup.html');
}
// Every label[for] points at an element.
for (const m of html.matchAll(/for="([^"]+)"/g)) assert.ok(html.includes('id="' + m[1] + '"'), 'label for ' + m[1]);
console.log('ok   popup.html: script order, ' + ids.size + ' ids resolved, labels wired');

// background.html and popup.html pin UTF-8, but if a page ever loses its
// charset again (as Safari's generated background page did), each script is
// decoded in the Mac's legacy encoding. Chinese text then only comes out
// garbled, as long as nothing that matters to the parser sits right after a
// non-ASCII character: in Big5, GBK and Shift_JIS the last byte of such a
// character can pair with the next ASCII byte (shared.js's /[‘’]/g lost its
// "]" that way). So non-ASCII characters in regular expressions are written
// as \u escapes, and every script these pages load must still parse when
// decoded as any of these.
for (const page of [manifest.background.page, manifest.action.default_popup]) {
  const pageScripts = [...fs.readFileSync(path.join(EXT, page), 'utf8').matchAll(/<script\s+src="([^"]+)"/g)].map((m) => m[1]);
  assert.ok(pageScripts.length, 'no scripts in ' + page);
  for (const file of pageScripts) {
    const bytes = fs.readFileSync(path.join(EXT, file));
    for (const encoding of ['big5', 'gbk', 'shift_jis']) {
      const source = new TextDecoder(encoding).decode(bytes);
      try {
        new vm.Script(source, { filename: file + ' as ' + encoding });
      } catch (e) {
        assert.fail(file + ' (loaded by ' + page + ') does not parse when decoded as ' + encoding + ': ' + e.message);
      }
    }
  }
  console.log('ok   ' + page + ': ' + pageScripts.join(', ') + ' parse as Big5, GBK and Shift_JIS too');
}

// shared.js + popup.js evaluate together in one realm (classic scripts sharing globals).
const ctx = vm.createContext({ document: { getElementById: () => null } , console });
vm.runInContext(fs.readFileSync(EXT + '/shared.js', 'utf8'), ctx);
assert.ok(ctx.MS);
console.log('ok   shared.js defines MS before popup.js runs');
console.log('\nlayout checks passed');

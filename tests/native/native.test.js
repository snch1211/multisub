'use strict';
// Builds the Swift files in MultiSub/Shared that the checks need (the app
// and the extension both compile them) together with tests/native/main.swift,
// and runs the result. The checks cover what decides, on disk alone, whether
// a local model is downloaded, and which model folders the app lists
// (MultiSubPaths), and which custom server addresses can be saved
// (CloudSettings.baseURLProblem). For each address it accepts, this file
// then checks that the WHATWG URL parser, which the popup uses to name the
// server in its consent step, finds the host and port Foundation sends to.
// Skips (exit 0) when not on macOS or when there is no Swift compiler.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const HERE = __dirname;
const SHARED = path.resolve(HERE, '../../MultiSub/Shared');
// Paths.swift needs AppIdentity.swift; Config.swift needs CloudLLM.swift
// (CloudProvider) and LanguageNames.swift.
const SOURCES = ['AppIdentity.swift', 'CloudLLM.swift', 'Config.swift', 'LanguageNames.swift', 'Paths.swift']
  .map((f) => path.join(SHARED, f));
const OUT = path.join(HERE, '.build', 'checks');

function skip(why) {
  console.log('skipped: ' + why);
  process.exit(0);
}

if (process.platform !== 'darwin') skip('the Swift checks need macOS');
if (spawnSync('xcrun', ['--find', 'swiftc'], { encoding: 'utf8' }).status !== 0) {
  skip('no Swift compiler (Xcode or the Command Line Tools are needed)');
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
// Same language mode and deployment target as the Xcode project.
const arch = os.arch() === 'arm64' ? 'arm64' : 'x86_64';
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-target', arch + '-apple-macos15.0',
  ...SOURCES, path.join(HERE, 'main.swift'), '-o', OUT], { encoding: 'utf8' });
if (build.status !== 0) {
  console.log('FAIL the checks did not build\n' + String(build.stderr || build.error || '').trim());
  process.exit(1);
}

const run = spawnSync(OUT, [], { encoding: 'utf8', timeout: 60000 });
const probes = [];
let result = null;
for (const line of String(run.stdout || '').split('\n')) {
  if (line.startsWith('PROBE ')) probes.push(JSON.parse(line.slice(6)));
  else if (line.startsWith('RESULT ')) result = JSON.parse(line.slice(7));
  else if (line) console.log(line);
}
if (run.stderr) console.log(String(run.stderr).trim());
if (!result) {
  console.log('FAIL the checks stopped early' + (run.signal ? ' (killed by ' + run.signal + ')' : ''));
  process.exit(1);
}

let { passed, failed } = result;
function test(name, fn) {
  try { fn(); passed++; console.log('ok   ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + '\n     ' + e.message); }
}

test('every accepted address names the same server in the popup (WHATWG) and in Foundation', () => {
  if (probes.length === 0) throw new Error('no addresses came back from the Swift checks');
  const defaultPort = (u) => (u.protocol === 'https:' ? 443 : 80);
  const mismatches = [];
  for (const p of probes) {
    let u;
    try { u = new URL(p.url.trim()); } catch (e) { mismatches.push(p.url + ': WHATWG cannot parse it'); continue; }
    // WHATWG keeps IPv6 brackets in hostname; Foundation's host has none.
    const host = u.hostname.replace(/^\[(.*)\]$/, '$1');
    const port = u.port ? Number(u.port) : defaultPort(u);
    const foundationPort = p.port == null ? defaultPort(u) : p.port;
    if (host !== p.host || port !== foundationPort) {
      mismatches.push(`${JSON.stringify(p.url)}: WHATWG ${host}:${port}, Foundation ${p.host}:${foundationPort}`);
    }
  }
  if (mismatches.length) throw new Error(mismatches.join('\n     '));
});

console.log('\n' + passed + ' tests passed' + (failed ? ', ' + failed + ' FAILED' : ''));
process.exit(failed ? 1 : 0);

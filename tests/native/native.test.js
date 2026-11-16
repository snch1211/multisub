'use strict';
// Builds the Swift files in MultiSub/Shared that the checks need (the app
// and the extension both compile them) together with tests/native/main.swift,
// and runs the result. The checks cover what decides, on disk alone, whether
// a local model is downloaded, and which model folders the app lists
// (MultiSubPaths).
// Skips (exit 0) when not on macOS or when there is no Swift compiler.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const HERE = __dirname;
const SHARED = path.resolve(HERE, '../../MultiSub/Shared');
// Paths.swift needs AppIdentity.swift.
const SOURCES = ['AppIdentity.swift', 'Paths.swift'].map((f) => path.join(SHARED, f));
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
process.stdout.write(String(run.stdout || ''));
if (run.status !== 0) {
  if (run.stderr) console.log(String(run.stderr).trim());
  if (run.signal) console.log('FAIL the checks were killed by ' + run.signal);
  process.exit(1);
}

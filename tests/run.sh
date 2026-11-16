#!/bin/bash
# Runs the extension's tests with Node (no packages to install).
# On macOS the WebKit harness (tests/webkit) is built first, so popup.test.js
# runs in WebKit and webkit.test.js can run; elsewhere, or if it doesn't
# build, popup.test.js uses Google Chrome and webkit.test.js skips.
# native.test.js compiles checks for the shared Swift code (MultiSub/Shared)
# with swiftc; it skips where there is none.
set -u
cd "$(dirname "$0")" || exit 1
if [[ "$(uname)" == Darwin ]] && ! webkit/build.sh >/dev/null 2>&1; then
  echo "(the WebKit harness did not build; popup runs in Chrome, webkit skips)"
fi
status=0
for t in extension/shared extension/background extension/content extension/layout extension/popup webkit/webkit native/native; do
  printf '%-11s ' "$(basename "$t")"
  if out=$(node "$t.test.js" 2>&1); then
    echo "$out" | tail -1
  else
    status=1
    echo "FAILED"
    echo "$out" | grep -A6 -E '^FAIL|Error' | head -40
  fi
done
exit $status

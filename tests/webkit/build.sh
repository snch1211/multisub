#!/bin/bash
# Builds the WebKit test harness into tests/webkit/.build/harness.
# Needs macOS 15.4 or later and the Xcode (or Command Line Tools) Swift
# compiler. Rebuilds only when a source file is newer than the binary.
# Usage: tests/webkit/build.sh [--force]
set -euo pipefail
cd "$(dirname "$0")"
out=.build/harness
srcs=(harness/*.swift)

if [[ "$(uname)" != Darwin ]]; then
  echo "build.sh: the WebKit harness needs macOS" >&2
  exit 2
fi

if [[ "${1:-}" != --force && -x $out ]]; then
  stale=0
  for f in "${srcs[@]}"; do [[ $f -nt $out ]] && stale=1; done
  [[ $stale == 0 ]] && exit 0
fi

mkdir -p .build
# WKWebExtensionController and friends need macOS 15.4.
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos15.4" \
  -module-name harness "${srcs[@]}" -o "$out.tmp"
mv "$out.tmp" "$out"
echo "built $(pwd)/$out" >&2

#!/bin/bash
# Renders the real extension popup (extension/popup.*) with a mocked
# browser API (mock.js) into ../assets/popup-<scenario>.png at 2×.
# Usage: ./render-popup.sh <scenario> <height>   e.g. ./render-popup.sh chooser 640
set -euo pipefail
cd "$(dirname "$0")"
S="${1:-chooser}"; H="${2:-640}"
EXT="../../../../extension"
TMP="$(mktemp -d)"
cp "$EXT/popup.css" "$EXT/popup.js" "$EXT/shared.js" mock.js "$TMP/"
# Load the mock before anything touches `browser`.
sed 's#<script src="shared.js"></script>#<script src="mock.js"></script><script src="shared.js"></script>#' "$EXT/popup.html" > "$TMP/popup.html"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=340,"$H" --virtual-time-budget=3000 \
  --screenshot="$PWD/../assets/popup-$S.png" "file://$TMP/popup.html?s=$S" >/dev/null 2>&1
rm -rf "$TMP"
echo "✓ assets/popup-$S.png"

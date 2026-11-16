#!/bin/bash
# render.sh — render the App Store screenshots (2880×1800 PNG, no alpha).
# Usage: ./render.sh            all shots, zh + en, into ./out
#        ./render.sh 2 zh       one shot
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p out
ids="${1:-1 2 3 4 5 6 7}"; langs="${2:-zh}"
for id in $ids; do for lang in $langs; do
  out="out/${lang}-${id}.png"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=2 --window-size=1440,900 --virtual-time-budget=1500 \
    --screenshot="$PWD/$out" "file://$PWD/shot.html?id=$id&lang=$lang" >/dev/null 2>&1
  # App Store rejects images with an alpha channel.
  sips -s format jpeg "$out" --out "${out%.png}.jpg" >/dev/null && sips -s format png "${out%.png}.jpg" --out "$out" >/dev/null && rm "${out%.png}.jpg"
  echo "✓ $out"
done; done

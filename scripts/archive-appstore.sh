#!/bin/bash
#
# archive-appstore.sh — build the Mac App Store version of MultiSub.
#
# Archives a Release build with MULTISUB_DISTRIBUTION=appstore (no GitHub
# self-updater, App Store entitlements; see MultiSub/MultiSub.xcconfig) and
# exports it for App Store Connect.
#
# Usage:
#   ./scripts/archive-appstore.sh            archive + export a signed .pkg into build/appstore/
#   ./scripts/archive-appstore.sh --upload   archive + upload straight to App Store Connect
#
# Needs: Xcode signed in to the Apple developer account that owns
# MULTISUB_BUNDLE_ID (set it and DEVELOPMENT_TEAM in MultiSub/Local.xcconfig).
# Signing certificates and profiles are created automatically
# (-allowProvisioningUpdates). The build number defaults to a timestamp so
# every upload is unique; override with BUILD_NUMBER=… if needed.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_DIR/MultiSub/MultiSub.xcodeproj"
OUT_DIR="$REPO_DIR/build/appstore"
ARCHIVE="$OUT_DIR/MultiSub.xcarchive"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DESTINATION="export"
[ "${1:-}" = "--upload" ] && DESTINATION="upload"

TEAM_ID="$(xcodebuild -project "$PROJECT" -scheme MultiSub -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ DEVELOPMENT_TEAM = /{print $2; exit}')"
if [ -z "$TEAM_ID" ]; then
  echo "✗ DEVELOPMENT_TEAM is empty. Set it in MultiSub/Local.xcconfig (see Local.xcconfig.example)."
  exit 1
fi

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/archive.log"

echo "▶︎ (1/2) Archiving (team $TEAM_ID, build $BUILD_NUMBER)…"
xcodebuild -project "$PROJECT" -scheme MultiSub -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates -skipPackagePluginValidation \
  MULTISUB_DISTRIBUTION=appstore CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive >"$LOG" 2>&1 \
  || { echo "✗ Archive failed — see $LOG"; tail -20 "$LOG"; exit 1; }
echo "  ✓ $ARCHIVE"

cat >"$OUT_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

echo "▶︎ (2/2) Exporting ($DESTINATION)…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT_DIR" \
  -exportOptionsPlist "$OUT_DIR/ExportOptions.plist" -allowProvisioningUpdates \
  >>"$LOG" 2>&1 \
  || { echo "✗ Export failed — see $LOG"; tail -20 "$LOG"; exit 1; }

if [ "$DESTINATION" = "upload" ]; then
  echo "完成 ✓ 已上傳 build $BUILD_NUMBER 到 App Store Connect（處理完成後會出現在 TestFlight / 版本頁面）。"
else
  echo "完成 ✓ $(ls "$OUT_DIR"/*.pkg 2>/dev/null | head -1)"
fi

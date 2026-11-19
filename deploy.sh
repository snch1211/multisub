#!/bin/bash
#
# deploy.sh — build MultiSub and install it into /Applications.
#
# Why this script exists:
#   Pressing "Run" in Xcode builds a *temporary* copy under DerivedData and
#   registers THAT with the system, which makes a duplicate show up in Safari.
#   The stable, "installed" copy lives in /Applications. This script rebuilds,
#   copies the fresh build into /Applications, and makes sure the system only
#   knows about that one copy.
#
# Usage:
#   ./deploy.sh            dev install: Debug build → /Applications (default)
#   ./deploy.sh --release  packaging: Developer ID–signed Release build →
#                          build/MultiSub.app (does NOT install to
#                          /Applications or touch Safari; feed the result to
#                          scripts/make-dmg.sh, which notarizes it)
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$REPO_DIR/MultiSub"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Every build gets a build number (CFBundleVersion) of its own, so Safari
# always sees an update and reloads the extension's files instead of going on
# with the ones it has from the previous build of the same version. The
# version (CFBundleShortVersionString, and the extension's manifest version)
# stays as set in the project. Same scheme as scripts/archive-appstore.sh
# (YYYYMMDDHHMM), plus the seconds as a second component, so two builds in one
# minute still differ and the numbers keep sorting with the App Store ones.
# Override with BUILD_NUMBER=… if needed.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M.%-S)}"

# ── Release build for DMG packaging ──────────────────────────────────────────
# Archives a Release build and exports it with the "developer-id" method:
# signed with the team's Developer ID Application certificate, hardened
# runtime on (set in the project), secure timestamp — everything notarization
# needs. Signing assets come from the team in MultiSub/Local.xcconfig and are
# created automatically (-allowProvisioningUpdates), the same way
# scripts/archive-appstore.sh does it for the App Store build.
# Stages build/MultiSub.app and stops there; scripts/make-dmg.sh packages,
# notarizes and staples it.
if [ "${1:-}" = "--release" ]; then
  OUT_DIR="$REPO_DIR/build"
  WORK_DIR="$OUT_DIR/direct"
  ARCHIVE="$WORK_DIR/MultiSub.xcarchive"
  LOG="$WORK_DIR/archive.log"
  mkdir -p "$WORK_DIR"
  cd "$PROJECT_DIR"

  TEAM_ID="$(xcodebuild -project MultiSub.xcodeproj -scheme MultiSub -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ DEVELOPMENT_TEAM = /{print $2; exit}')"
  if [ -z "$TEAM_ID" ]; then
    echo "✗ DEVELOPMENT_TEAM 是空的，請在 MultiSub/Local.xcconfig 設定（參考 Local.xcconfig.example）"
    exit 1
  fi

  echo "▶︎ (1/4) Archive（Release，team $TEAM_ID，第一次或大改動可能要幾分鐘）…"
  rm -rf "$ARCHIVE"
  xcodebuild -project MultiSub.xcodeproj -scheme MultiSub -configuration Release \
    -archivePath "$ARCHIVE" ENABLE_DEBUG_DYLIB=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MULTISUB_DISTRIBUTION=direct \
    -skipPackagePluginValidation -skipMacroValidation \
    -allowProvisioningUpdates archive >"$LOG" 2>&1 \
    || { echo "✗ Archive 失敗，詳見 $LOG"; tail -20 "$LOG"; exit 1; }
  echo "  ✓ ARCHIVE SUCCEEDED (build $BUILD_NUMBER)"

  # Same reason as scripts/archive-appstore.sh: the archive and DerivedData
  # copies get registered with LaunchServices, and Safari may then launch the
  # extension's native handler from one of them. Keep only /Applications.
  for app in "$ARCHIVE/Products/Applications/MultiSub.app" \
             "$(ls -d ~/Library/Developer/Xcode/DerivedData/MultiSub-*/Build/Intermediates.noindex/ArchiveIntermediates/MultiSub/InstallationBuildProductsLocation/Applications/MultiSub.app 2>/dev/null | head -1)"; do
    [ -d "$app" ] || continue
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    pluginkit -r "$app/Contents/PlugIns/MultiSub Extension.appex" >/dev/null 2>&1 || true
  done
  [ -d /Applications/MultiSub.app ] && "$LSREGISTER" -f /Applications/MultiSub.app >/dev/null 2>&1 || true

  echo "▶︎ (2/4) 以 Developer ID 匯出…"
  cat >"$WORK_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
  rm -rf "$WORK_DIR/export"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK_DIR/export" \
    -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" -allowProvisioningUpdates \
    >>"$LOG" 2>&1 \
    || { echo "✗ 匯出失敗，詳見 $LOG"; tail -20 "$LOG"; exit 1; }

  echo "▶︎ (3/4) 複製到 build/MultiSub.app…"
  rm -rf "$OUT_DIR/MultiSub.app"
  cp -R "$WORK_DIR/export/MultiSub.app" "$OUT_DIR/MultiSub.app"
  echo "  ✓ $OUT_DIR/MultiSub.app"

  echo "▶︎ (4/4) 驗證簽章…"
  codesign --verify --deep --strict "$OUT_DIR/MultiSub.app" \
    || { echo "✗ 簽章驗證失敗"; exit 1; }
  # Read codesign's output once, then parse it: piping it straight into a
  # filter that stops early (awk exit / grep -q) trips pipefail and set -e.
  SIGN_INFO="$(codesign -dvv "$OUT_DIR/MultiSub.app" 2>&1)"
  SIGNER="$(awk -F= '/^Authority=/{print $2; exit}' <<<"$SIGN_INFO")"
  case "$SIGNER" in
    "Developer ID Application:"*) echo "  ✓ 簽章有效（$SIGNER）" ;;
    *) echo "✗ 不是 Developer ID 簽章（${SIGNER:-未簽章}），無法公證"; exit 1 ;;
  esac
  grep -q 'flags=.*runtime' <<<"$SIGN_INFO" \
    || { echo "✗ 沒有開 Hardened Runtime，無法公證"; exit 1; }
  echo "  ✓ Hardened Runtime 已開啟"

  VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$OUT_DIR/MultiSub.app/Contents/Info.plist" 2>/dev/null || echo '?')"
  echo ""
  echo "完成 ✓  Release 版本 $VER → build/MultiSub.app"
  echo "下一步：./scripts/make-dmg.sh   （打包成 DMG + SHA256）"
  exit 0
fi
# ─────────────────────────────────────────────────────────────────────────────

echo "▶︎ (1/5) 建置 App（第一次或大改動可能要幾分鐘）…"
cd "$PROJECT_DIR"
xcodebuild -project MultiSub.xcodeproj -scheme MultiSub -configuration Debug \
  ENABLE_DEBUG_DYLIB=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -skipPackagePluginValidation -skipMacroValidation \
  -allowProvisioningUpdates build >/tmp/multisub-build.log 2>&1 \
  || { echo "✗ 建置失敗，詳見 /tmp/multisub-build.log"; tail -20 /tmp/multisub-build.log; exit 1; }
echo "  ✓ BUILD SUCCEEDED (build $BUILD_NUMBER)"

# Find the freshly built app inside Xcode's hidden build folder (DerivedData).
BUILT_APP="$(ls -td ~/Library/Developer/Xcode/DerivedData/MultiSub-*/Build/Products/Debug/MultiSub.app 2>/dev/null | head -1)"
if [ -z "$BUILT_APP" ] || [ ! -d "$BUILT_APP" ]; then
  echo "✗ 找不到剛建好的 App，中止"; exit 1
fi

echo "▶︎ (2/5) 關閉正在執行的 MultiSub（若有）…"
osascript -e 'tell application "MultiSub" to quit' 2>/dev/null || true
pkill -f "MultiSub.app/Contents/MacOS/MultiSub" 2>/dev/null || true
sleep 1

echo "▶︎ (3/5) 複製到 /Applications…"
rm -rf /Applications/MultiSub.app
cp -R "$BUILT_APP" /Applications/
echo "  ✓ 已安裝到 /Applications/MultiSub.app"

echo "▶︎ (4/5) 驗證簽章 + 只登錄 /Applications 這一份（移除 DerivedData 暫存副本）…"
codesign --verify --deep --strict /Applications/MultiSub.app \
  && echo "  ✓ 簽章有效" || { echo "✗ 簽章驗證失敗"; exit 1; }
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true   # unregister the temp copy
# Delete it too: if anything launches the DerivedData copy later (Xcode's Run,
# a script, Spotlight), LaunchServices registers it again and Safari lists a
# second MultiSub that can't reach its app. The next build recreates it.
rm -rf "$BUILT_APP"
"$LSREGISTER" -f /Applications/MultiSub.app             # register the real one

echo "▶︎ (5/5) 完成 ✓"
echo ""
echo "每次建置的版本號都不同，Safari 會自己載入新版。接下來："
echo "  1. Netflix 分頁按 ⌘R 重新整理"
echo "  2. 選單看起來還是舊的，再到 Safari 設定 → 延伸功能，把 MultiSub 取消勾選再勾回來"
echo ""
echo "只是想用 App：⌘空白鍵 打 MultiSub 開啟即可，不用進 Xcode。"

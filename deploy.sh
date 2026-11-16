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
#   ./deploy.sh --release  packaging: Release build → build/MultiSub.app
#                          (does NOT install to /Applications or touch Safari;
#                           feed the result to scripts/make-dmg.sh)
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$REPO_DIR/MultiSub"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# ── Release build for DMG packaging ──────────────────────────────────────────
# Uses the same mandatory flags as the Debug path below, only with
# -configuration Release. Free signing — no hardened runtime / no
# notarization. Stages a clean copy at build/MultiSub.app and stops there.
if [ "${1:-}" = "--release" ]; then
  OUT_DIR="$REPO_DIR/build"
  echo "▶︎ (1/3) 建置 App（Release，第一次或大改動可能要幾分鐘）…"
  cd "$PROJECT_DIR"
  xcodebuild -project MultiSub.xcodeproj -scheme MultiSub -configuration Release \
    ENABLE_DEBUG_DYLIB=NO -skipPackagePluginValidation -skipMacroValidation \
    -allowProvisioningUpdates build >/tmp/multisub-build.log 2>&1 \
    || { echo "✗ 建置失敗，詳見 /tmp/multisub-build.log"; tail -20 /tmp/multisub-build.log; exit 1; }
  echo "  ✓ BUILD SUCCEEDED"

  BUILT_APP="$(ls -td ~/Library/Developer/Xcode/DerivedData/MultiSub-*/Build/Products/Release/MultiSub.app 2>/dev/null | head -1)"
  if [ -z "$BUILT_APP" ] || [ ! -d "$BUILT_APP" ]; then
    echo "✗ 找不到剛建好的 Release App，中止"; exit 1
  fi

  echo "▶︎ (2/3) 複製到 build/MultiSub.app…"
  mkdir -p "$OUT_DIR"
  rm -rf "$OUT_DIR/MultiSub.app"
  cp -R "$BUILT_APP" "$OUT_DIR/MultiSub.app"
  echo "  ✓ $OUT_DIR/MultiSub.app"

  echo "▶︎ (3/3) 驗證簽章…"
  codesign --verify --deep --strict "$OUT_DIR/MultiSub.app" \
    && echo "  ✓ 簽章有效" || { echo "✗ 簽章驗證失敗"; exit 1; }

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
  ENABLE_DEBUG_DYLIB=NO -skipPackagePluginValidation -skipMacroValidation \
  -allowProvisioningUpdates build >/tmp/multisub-build.log 2>&1 \
  || { echo "✗ 建置失敗，詳見 /tmp/multisub-build.log"; tail -20 /tmp/multisub-build.log; exit 1; }
echo "  ✓ BUILD SUCCEEDED"

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
"$LSREGISTER" -f /Applications/MultiSub.app             # register the real one

echo "▶︎ (5/5) 完成 ✓"
echo ""
echo "接下來要讓 Safari 載入新版："
echo "  1. Safari 設定 → 延伸功能 → MultiSub 取消勾選再重新勾選（重載資源）"
echo "  2. Netflix 分頁按 ⌘R 重新整理"
echo ""
echo "只是想用 App：⌘空白鍵 打 MultiSub 開啟即可，不用進 Xcode。"

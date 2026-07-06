#!/bin/bash
#
# make-dmg.sh — package the Release build into a distributable DMG (R4).
#
# Produces build/MultiSub-<version>.dmg (UDZO) with a styled install window:
# a dark on-brand background, the app icon on the left, an /Applications
# symlink on the right, and a "drag here" arrow between them. Also writes a
# .sha256 checksum for the GitHub Release.
#
# Route 1 (free signing, PLAN.md R1): NOT notarized. On other machines
# Gatekeeper blocks it until the user approves it manually — the Release notes
# and website cover that step. No npm / create-dmg dependency; hdiutil +
# Finder (AppleScript) only.
#
# Prereq:  ./deploy.sh --release      (stages build/MultiSub.app)
# Usage:   ./scripts/make-dmg.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
APP="$BUILD_DIR/MultiSub.app"
ASSETS_DIR="$REPO_DIR/scripts/dmg-assets"
BG_TIFF="$ASSETS_DIR/dmg-background.tiff"   # multi-rep (1×+2×) for Retina crispness

if [ ! -d "$APP" ]; then
  echo "✗ 找不到 $APP"
  echo "  請先執行：./deploy.sh --release"
  exit 1
fi

# Regenerate the window background if missing (committed, but be safe).
if [ ! -f "$BG_TIFF" ]; then
  echo "▶︎ 產生 DMG 背景圖…"
  swift "$ASSETS_DIR/make-dmg-background.swift"
fi

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLNAME="MultiSub $VER"
DMG="$BUILD_DIR/MultiSub-$VER.dmg"
RW_DMG="$BUILD_DIR/.MultiSub-$VER-rw.dmg"

STAGING="$(mktemp -d)"
MOUNT=""
RW_VOL="/Volumes/$VOLNAME"   # RW disk must mount here so Finder can address it
cleanup() {
  hdiutil detach "$RW_VOL" -quiet 2>/dev/null || true
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$STAGING"
  [ -n "$MOUNT" ] && rm -rf "$MOUNT"
  rm -f "$RW_DMG"
}
trap cleanup EXIT

echo "▶︎ (1/5) 準備暫存內容（App + /Applications 捷徑 + 背景）…"
cp -R "$APP" "$STAGING/MultiSub.app"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$BG_TIFF" "$STAGING/.background/dmg-background.tiff"

echo "▶︎ (2/5) 建立可寫入 DMG…"
rm -f "$RW_DMG" "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" \
  -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

echo "▶︎ (3/5) 掛載並用 Finder 排版（背景／圖示位置）…"
# Must mount at the default /Volumes/<name>; Finder addresses the volume by
# name (`disk "..."`) and can't find one mounted at a private temp path.
hdiutil detach "$RW_VOL" -quiet 2>/dev/null || true   # clear any stale mount
hdiutil attach "$RW_DMG" -noautoopen -quiet >/dev/null
sleep 1
if STYLE_ERR="$(osascript 2>&1 <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {440, 200, 1080, 628}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:dmg-background.tiff"
    set position of item "MultiSub.app" of container window to {170, 205}
    set position of item "Applications" of container window to {470, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
)"; then
  echo "  ✓ 排版完成"
else
  echo "  ⚠︎ Finder 排版未成功：${STYLE_ERR:-unknown}"
  echo "     若錯誤是「Not authorized ...」/ -1743：系統設定 → 隱私權與安全性 →"
  echo "     自動化 → 允許你的終端機控制「Finder」，然後再重跑一次本腳本。"
  echo "     （DMG 仍會產出，只是預設排版無背景。）"
fi
sync; sleep 1
hdiutil detach "$RW_VOL" -quiet

echo "▶︎ (4/5) 壓縮為 UDZO…"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" >/dev/null

echo "▶︎ (5/5) 驗證簽章 + 計算 SHA256…"
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
codesign --verify --deep --strict "$MOUNT/MultiSub.app" \
  && echo "  ✓ DMG 內 App 簽章有效" \
  || { echo "✗ 簽章驗證失敗"; exit 1; }
hdiutil detach "$MOUNT" -quiet
MOUNT=""
( cd "$BUILD_DIR" && shasum -a 256 "MultiSub-$VER.dmg" | tee "MultiSub-$VER.dmg.sha256" )

echo ""
echo "完成 ✓"
echo "  DMG    : $DMG"
echo "  SHA256 : $DMG.sha256"
echo ""
echo "上傳到 GitHub Release 時，DMG 與 .sha256 兩個檔都要附。"

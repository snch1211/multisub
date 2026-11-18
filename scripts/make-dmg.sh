#!/bin/bash
#
# make-dmg.sh — package the Release build into a distributable DMG.
#
# Produces build/MultiSub-<version>.dmg (UDZO) with a styled install window:
# a dark on-brand background, the app icon on the left, an /Applications
# symlink on the right, and a "drag here" arrow between them. Also writes a
# .sha256 checksum for the GitHub Release.
#
# The DMG is signed with the same Developer ID as the app, notarized by Apple
# and stapled, so Gatekeeper opens it on any Mac without a manual approval
# (and Homebrew can install it). No npm / create-dmg dependency; hdiutil +
# Finder (AppleScript) + notarytool only.
#
# Prereq:  ./deploy.sh --release      (stages a Developer ID build/MultiSub.app)
#          a notarytool keychain profile, created once per Mac:
#            xcrun notarytool store-credentials multisub-notary \
#              --apple-id <Apple ID> --team-id <Team ID>
#          (asks for an app-specific password from account.apple.com)
# Usage:   ./scripts/make-dmg.sh
#          NOTARY_PROFILE=<name> ./scripts/make-dmg.sh   other profile name
#          NOTARIZE=0 ./scripts/make-dmg.sh              local test DMG only —
#                                                        not for release
#
set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-multisub-notary}"
NOTARIZE="${NOTARIZE:-1}"

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

# The DMG is signed with the identity that signed the app, so both carry the
# same Developer ID. Checked before any packaging work.
SIGN_IDENTITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
case "$SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "✗ $APP 不是 Developer ID 簽章（${SIGN_IDENTITY:-未簽章}）"
     echo "  請用 ./deploy.sh --release 重新建置"
     exit 1 ;;
esac

if [ "$NOTARIZE" = "1" ]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗ 找不到公證用的鑰匙圈設定檔「$NOTARY_PROFILE」，請先執行一次："
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id <Team ID>"
    echo "  （密碼要用 account.apple.com 產生的 App 專用密碼）"
    exit 1
  fi
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

echo "▶︎ (1/6) 準備暫存內容（App + /Applications 捷徑 + 背景）…"
cp -R "$APP" "$STAGING/MultiSub.app"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$BG_TIFF" "$STAGING/.background/dmg-background.tiff"

echo "▶︎ (2/6) 建立可寫入 DMG…"
rm -f "$RW_DMG" "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" \
  -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

echo "▶︎ (3/6) 掛載並用 Finder 排版（背景／圖示位置）…"
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

echo "▶︎ (4/6) 壓縮為 UDZO 並簽章…"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" >/dev/null
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
echo "  ✓ 以 $SIGN_IDENTITY 簽章"

if [ "$NOTARIZE" = "1" ]; then
  echo "▶︎ (5/6) 送 Apple 公證（通常 1–5 分鐘）…"
  NOTARY_LOG="$BUILD_DIR/notary-$VER.json"
  if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
       --wait --output-format json >"$NOTARY_LOG"; then
    echo "✗ 送審失敗，詳見 $NOTARY_LOG"; exit 1
  fi
  STATUS="$(/usr/bin/plutil -extract status raw "$NOTARY_LOG" 2>/dev/null || echo '?')"
  SUBMISSION="$(/usr/bin/plutil -extract id raw "$NOTARY_LOG" 2>/dev/null || echo '?')"
  if [ "$STATUS" != "Accepted" ]; then
    echo "✗ 公證未通過（$STATUS）。原因："
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
  fi
  echo "  ✓ 公證通過（$SUBMISSION）"
  xcrun stapler staple "$DMG" >/dev/null
  echo "  ✓ 已把公證結果釘進 DMG"
else
  echo "▶︎ (5/6) 略過公證（NOTARIZE=0）— 這個 DMG 只能自己測試，不要發行"
fi

echo "▶︎ (6/6) 驗證簽章與 Gatekeeper + 計算 SHA256…"
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
codesign --verify --deep --strict "$MOUNT/MultiSub.app" \
  && echo "  ✓ DMG 內 App 簽章有效" \
  || { echo "✗ 簽章驗證失敗"; exit 1; }
if [ "$NOTARIZE" = "1" ]; then
  xcrun stapler validate "$DMG" >/dev/null \
    || { echo "✗ DMG 沒有釘上公證結果"; exit 1; }
  spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null \
    || { echo "✗ Gatekeeper 不接受這個 DMG"; spctl -a -vv -t open --context context:primary-signature "$DMG"; exit 1; }
  spctl --assess --type execute "$MOUNT/MultiSub.app" 2>/dev/null \
    || { echo "✗ Gatekeeper 不接受 DMG 內的 App"; spctl -a -vv "$MOUNT/MultiSub.app"; exit 1; }
  echo "  ✓ Gatekeeper 接受 DMG 與 App（Notarized Developer ID）"
fi
hdiutil detach "$MOUNT" -quiet
MOUNT=""
( cd "$BUILD_DIR" && shasum -a 256 "MultiSub-$VER.dmg" | tee "MultiSub-$VER.dmg.sha256" )

echo ""
echo "完成 ✓"
echo "  DMG    : $DMG"
echo "  SHA256 : $DMG.sha256"
echo ""
echo "上傳到 GitHub Release 時，DMG 與 .sha256 兩個檔都要附。"
echo "發行後記得更新 Homebrew tap 的 Casks/multisub.rb（version + sha256）。"

#!/bin/bash
#
# make-cask.sh — write the Homebrew cask for the DMG that make-dmg.sh built.
#
# Produces build/homebrew/Casks/multisub.rb with the version and SHA256 of
# build/MultiSub-<version>.dmg. Copy it into the tap repo (homebrew-multisub)
# after the DMG is uploaded to the GitHub Release, so the URL in the cask
# resolves.
#
# Prereq:  ./scripts/make-dmg.sh          (notarized DMG + .sha256)
# Usage:   ./scripts/make-cask.sh
#          RELEASE_REPO=owner/name ./scripts/make-cask.sh   other release repo
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
APP="$BUILD_DIR/MultiSub.app"
RELEASE_REPO="${RELEASE_REPO:-ncchen99/Multisub}"   # same repo as UpdateChecker.swift

[ -d "$APP" ] || { echo "✗ 找不到 $APP，請先執行 ./deploy.sh --release"; exit 1; }
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
SIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
TEAM_ID="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$SIGN_INFO")"
SHA_FILE="$BUILD_DIR/MultiSub-$VER.dmg.sha256"
[ -f "$SHA_FILE" ] || { echo "✗ 找不到 $SHA_FILE，請先執行 ./scripts/make-dmg.sh"; exit 1; }
SHA="$(awk '{print $1}' "$SHA_FILE")"

# A cask must point at a DMG Gatekeeper accepts; refuse a NOTARIZE=0 test DMG.
xcrun stapler validate "$BUILD_DIR/MultiSub-$VER.dmg" >/dev/null 2>&1 \
  || { echo "✗ MultiSub-$VER.dmg 沒有公證，不能拿來做 cask（NOTARIZE=0 的測試版？）"; exit 1; }

OUT="$BUILD_DIR/homebrew/Casks/multisub.rb"
mkdir -p "$(dirname "$OUT")"
cat >"$OUT" <<EOF
cask "multisub" do
  version "$VER"
  sha256 "$SHA"

  url "https://github.com/$RELEASE_REPO/releases/download/v#{version}/MultiSub-#{version}.dmg"
  name "MultiSub"
  desc "Dual-language Netflix subtitles in Safari"
  homepage "https://github.com/$RELEASE_REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "MultiSub.app"

  zap trash: [
    "~/Library/Application Scripts/$BUNDLE_ID",
    "~/Library/Application Scripts/$BUNDLE_ID.Extension",
    "~/Library/Application Scripts/$TEAM_ID.$BUNDLE_ID",
    "~/Library/Containers/$BUNDLE_ID",
    "~/Library/Containers/$BUNDLE_ID.Extension",
    "~/Library/Group Containers/$TEAM_ID.$BUNDLE_ID",
  ]

  caveats <<~EOS
    Open MultiSub once, then enable it in Safari › Settings › Extensions.
  EOS
end
EOF

echo "完成 ✓  $OUT（$VER）"
echo "DMG 上傳到 https://github.com/$RELEASE_REPO/releases/tag/v$VER 之後，"
echo "把這個檔案複製到 tap repo 的 Casks/multisub.rb 再 push。"

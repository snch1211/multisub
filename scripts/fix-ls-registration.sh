#!/bin/bash
#
# fix-ls-registration.sh — recover from Safari's
#   "The operation couldn't be completed. (SFErrorDomain error 1)"
#
# Cause (dev machines only): several copies of MultiSub.app with the SAME
# bundle ID get registered with LaunchServices at once — the /Applications
# install, Xcode's DerivedData Debug/Release builds, build/MultiSub.app from
# `deploy.sh --release`, a mounted DMG volume, a Trash copy… Safari then can't
# decide which extension bundle to load and errors out. End users never hit
# this (they have exactly one copy in /Applications).
#
# This unmounts any MultiSub DMG, unregisters every copy that isn't the
# /Applications one, then re-registers /Applications so it's the only match.
# Afterwards: quit Safari (⌘Q), reopen, re-enable the extension.
#
# Usage:  ./scripts/fix-ls-registration.sh
#
set -euo pipefail

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "▶︎ 1) 退載所有掛載中的 MultiSub 卷宗…"
shopt -s nullglob 2>/dev/null || true
for v in /Volumes/MultiSub*; do
  hdiutil detach "$v" -force -quiet 2>/dev/null && echo "  ✓ 退載 $v" || true
done

echo "▶︎ 2) 取消登錄所有『非 /Applications』的 MultiSub 副本…"
"$LSREGISTER" -dump 2>/dev/null \
  | grep -oE "path: +/[^ ]+MultiSub\.app" | sed 's/path: *//' | sort -u \
  | while read -r p; do
      [ "$p" = "/Applications/MultiSub.app" ] && continue
      "$LSREGISTER" -u "$p" >/dev/null 2>&1 && echo "  -u $p" || true
    done

echo "▶︎ 3) 只重新登錄 /Applications 那一份…"
if [ -d /Applications/MultiSub.app ]; then
  "$LSREGISTER" -f /Applications/MultiSub.app && echo "  ✓ 已登錄"
else
  echo "  ⚠︎ /Applications/MultiSub.app 不存在——請先從 DMG 拖進 Applications"
fi

echo ""
echo "=== 目前仍登錄的 MultiSub 路徑（正常應只剩 /Applications 一份 appex）==="
"$LSREGISTER" -dump 2>/dev/null | grep -iE "path:.*MultiSub(\.app| Extension)" | sort -u || true

echo ""
echo "接著：完全結束 Safari（⌘Q）→ 重開 → 設定→擴充功能 重新勾選 MultiSub。"

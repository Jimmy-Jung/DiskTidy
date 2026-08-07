#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="DiskTidy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/DiskTidy" "$APP/Contents/MacOS/DiskTidy"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 서명 (무료). --deep는 Apple이 deprecated 처리했고 의존 번들도 없어 생략.
# 배포용으로 공증하려면 Developer ID + --options runtime + notarytool이 필요하다.
codesign --force --sign - "$APP"

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/$APP"

echo "설치 완료: $DEST/$APP"

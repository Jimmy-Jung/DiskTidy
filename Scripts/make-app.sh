#!/bin/bash
# DiskTidy.app 번들만 만든다. 설치도 배포도 하지 않는다.
# build-app.sh(로컬 설치)와 make-dmg.sh(배포용 DMG)가 공유한다.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="DiskTidy.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/DiskTidy" "$APP/Contents/MacOS/DiskTidy"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 서명 (무료). --deep는 Apple이 deprecated 처리했고 의존 번들도 없어 생략.
# 배포용으로 공증하려면 Developer ID + --options runtime + notarytool이 필요하다.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "번들 생성 완료: $APP"

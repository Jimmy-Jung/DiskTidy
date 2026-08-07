#!/bin/bash
# 배포용 DMG를 만든다. hdiutil은 macOS 기본 내장이라 추가 의존성이 없다.
# 결과물: dist/DiskTidy-<version>.dmg (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="DiskTidy.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DIST="dist"
DMG="$DIST/DiskTidy-$VERSION.dmg"

./Scripts/make-app.sh

# 스테이징 폴더: 앱 + /Applications 심볼릭 링크.
# 링크가 있으면 사용자가 DMG를 열어 앱을 끌어다 놓는 것으로 설치가 끝난다.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create \
    -volname "DiskTidy $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo ""
echo "DMG 생성 완료: $DMG ($(du -h "$DMG" | cut -f1))"
echo ""
echo "주의: ad-hoc 서명이라 공증되지 않았다. 받는 사람은 첫 실행 때"
echo "System Settings > Privacy & Security > '확인 없이 열기'를 눌러야 한다."
echo "자세한 안내는 README의 '첫 실행' 절 참고."

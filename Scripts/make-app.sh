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

# 릴리스 빌드는 `.build/release`에 SPM 리소스 번들(Highlightr·SwiftMath)을 남기지만
# 일부러 넣지 않는다. SPM이 만든 `Bundle.module` 접근자는 `.app` 루트에서 번들을 찾는데,
# 루트에 파일을 두면 codesign이 "unsealed contents present in the bundle root"로 서명을
# 거부한다(실측). 대신 그 리소스를 요구하는 코드 경로를 아예 타지 않게 해 두었다 —
# 자세한 사정은 `Sources/DiskTidy/Views/ChatMarkdownStyle.swift`의 `ChatCodeBlockStyle` 주석.

# ad-hoc 서명 (무료). --deep는 Apple이 deprecated 처리했고 넣을 의존 번들도 없어 생략.
# 배포용으로 공증하려면 Developer ID + --options runtime + notarytool이 필요하다.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "번들 생성 완료: $APP"

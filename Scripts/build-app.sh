#!/bin/bash
# 로컬 설치용. 빌드 후 /Applications에 넣는다 — DMG 배포판과 같은 자리다.
#
# `~/Applications`에 넣으면 배포판이 들어가는 `/Applications`와 갈라져 같은 번들 ID의
# 앱이 두 곳에 남는다. 그러면 LaunchServices가 어느 쪽을 열지 보장하지 않아, 인앱
# 업데이트가 교체한 앱과 실제로 열리는 앱이 달라진다(실측: 1.0과 1.2.0이 공존했다).
#
# `/Applications`는 `root:admin`에 그룹 쓰기가 열려 있어 관리자 계정이면 sudo가 필요 없다.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/make-app.sh

APP="DiskTidy.app"
DEST="/Applications"

if [ ! -w "$DEST" ]; then
    echo "오류: $DEST에 쓸 권한이 없습니다. 관리자 계정으로 실행하세요." >&2
    exit 1
fi

# 실행 중인 앱을 교체해도 그 프로세스는 계속 산다(매핑된 이미지는 inode로 유지된다).
# 다만 새 코드로 도는 것은 아니므로 종료하고 다시 열어야 한다.
if pgrep -f "$DEST/$APP/Contents/MacOS/DiskTidy" > /dev/null; then
    echo "주의: DiskTidy가 실행 중입니다. 설치 후 종료하고 다시 열어야 새 버전이 뜹니다."
fi

rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/$APP"

echo "설치 완료: $DEST/$APP"

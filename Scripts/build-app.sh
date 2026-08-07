#!/bin/bash
# 로컬 설치용. 빌드 후 ~/Applications에 넣는다.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/make-app.sh

APP="DiskTidy.app"
DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/$APP"

echo "설치 완료: $DEST/$APP"

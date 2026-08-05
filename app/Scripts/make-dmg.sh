#!/bin/bash
set -euo pipefail

# Собирает готовый к раздаче образ: приложение + ярлык «Программы».
# Расширение уже внутри бандла (Contents/Resources/extension).

cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Scripts/Info.plist)}"
export VERSION

APP="dist/Sordio.app"
DMG="dist/Sordio-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

./Scripts/build-app.sh release

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -srcfolder "$STAGE" -volname "Sordio $VERSION" \
    -fs HFS+ -format UDZO "$DMG"

echo "✓ Образ: $DMG"
shasum -a 256 "$DMG"

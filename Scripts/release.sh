#!/bin/bash
set -euo pipefail

# Выпуск версии: universal-сборка → DMG → релиз на GitHub → формула Homebrew.
#
# Формула не пишется руками: в ней версия и контрольная сумма образа, которые
# известны только после сборки, поэтому её каждый раз перегенерирует этот
# скрипт.

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Использование: ./Scripts/release.sh <версия>   (например 0.2.0)" >&2
    exit 1
fi

REPO="samplec0de/sordio"
TAG="v$VERSION"
DMG="app/dist/Sordio-${VERSION}.dmg"

# Формулу `brew tap` читает с ветки по умолчанию. Выпуск с любой другой ветки
# положил бы её мимо, и `brew install --cask sordio` не нашёл бы каск.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "✗ Выпуск делается с main, а сейчас $BRANCH." >&2
    exit 1
fi

# Релиз создаёт gh в $REPO, а тег и формулу толкает git в origin. Если они
# разъедутся, образ окажется в одном репозитории, а тег с формулой в другом.
if ! git remote get-url origin | grep -q "$REPO"; then
    echo "✗ origin ($(git remote get-url origin)) не совпадает с $REPO." >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "Sordio Dev"; then
    echo "✗ Сертификата «Sordio Dev» нет в связке ключей." >&2
    echo "  Выпуск, подписанный чем-то другим, сбросит выданные разрешения" >&2
    echo "  у всех, кому приложение уже поставлено. См. app/Scripts/SIGNING.md" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "✗ В рабочей копии есть незакоммиченные изменения." >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "→ тесты"
(cd app && swift test >/dev/null)
(cd extension && npm test --silent >/dev/null)

# Версию раньше правили руками в двух местах и забывали: build-app.sh
# подставляет её только в собранный бандл, а манифест расширения копируется
# как есть — и внутрь образа уезжало расширение от прошлой версии.
echo "→ версия $VERSION в Info.plist и манифест расширения"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" app/Scripts/Info.plist
sed -i '' -E "s/(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*\"/\1$VERSION\"/" \
    extension/manifest.json extension/package.json

echo "→ сборка образа $VERSION"
(cd app && VERSION="$VERSION" ./Scripts/make-dmg.sh >/dev/null)

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

mkdir -p Casks
cat > Casks/sordio.rb <<EOF
# Файл создаётся скриптом Scripts/release.sh — править руками бессмысленно.
cask "sordio" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Sordio-#{version}.dmg"
  name "Sordio"
  desc "Микрофон SaluteJazz глобальным хоткеем и плашкой поверх окон"
  homepage "https://github.com/$REPO"

  app "Sordio.app"

  postflight do
    # Приложение подписано собственным сертификатом, а не Developer ID, и
    # Gatekeeper отказывается открывать его, пока на файлах висит карантинная
    # метка: «Apple could not verify Sordio.app is free of malware». Флага
    # --no-quarantine в Homebrew 6 больше нет, так что метку снимаем здесь —
    # иначе это пришлось бы делать руками каждому, кто ставит приложение.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Sordio.app"]
  end

  caveats <<~CAVEATS
    Осталось два шага:
      1. Запустить Sordio и выдать «Универсальный доступ» и «Мониторинг ввода»
         в «Конфиденциальность и безопасность», затем перезапустить приложение.
      2. В меню строки состояния выбрать «Показать папку расширения» и
         загрузить её на chrome://extensions как распакованное расширение.
  CAVEATS

  zap trash: [
    "~/Library/Preferences/ru.sordio.app.plist",
  ]
end
EOF

# Сначала коммит со всем содержимым выпуска, и только потом тег: иначе тег
# указывал бы на состояние без поднятых версий и без формулы.
git add Casks/sordio.rb app/Scripts/Info.plist extension/manifest.json extension/package.json
git commit -q -m "release: Sordio $VERSION"

echo "→ релиз $TAG"
git tag -f "$TAG"
git push origin HEAD
git push origin "$TAG" --force-with-lease 2>/dev/null || git push origin "$TAG"
gh release create "$TAG" "$DMG" --repo "$REPO" --title "Sordio $VERSION" \
    --notes "Установка и обновление — в README." 2>/dev/null \
    || gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber

echo "✓ Sordio $VERSION опубликован"
echo "  brew upgrade --cask sordio"

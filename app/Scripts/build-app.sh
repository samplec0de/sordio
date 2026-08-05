#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="dist/Sordio.app"
VERSION="${VERSION:-}"

# Для раздачи собираем универсальный бинарник: у пользователей может оказаться Intel,
# а проверить это заранее нельзя. В отладке лишняя архитектура только замедляет.
ARCH_FLAGS=()
if [ "$CONFIG" = "release" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "→ swift build -c $CONFIG ${ARCH_FLAGS[*]:-}"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]:+"${ARCH_FLAGS[@]}"}

BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]:+"${ARCH_FLAGS[@]}"} --show-bin-path)/Sordio"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sordio"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

# Расширение кладём внутрь бандла: ставить его всё равно приходится вручную,
# а так оно гарантированно той же версии, что и приложение. Пункт меню
# «Показать папку расширения» открывает именно эту папку.
if [ "$CONFIG" = "release" ]; then
    echo "→ сборка расширения"
    (cd ../extension && npm run build >/dev/null)
fi
if [ -d ../extension/dist ]; then
    cp -R ../extension/dist "$APP/Contents/Resources/extension"
else
    echo "⚠️  extension/dist нет — расширение в бандл не попало"
fi

IDENTITY="Sordio Dev"
# Прав приложению не нужно: микрофон оно не открывает — уровень считает
# расширение по клону дорожки страницы.
#
# Подписывать каждую сборку одним и тем же сертификатом обязательно: TCC
# привязывает выданные разрешения к подписи, и смена сертификата сбросит их
# и здесь, и у всех, кому приложение уже поставлено.
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "→ подпись сертификатом «${IDENTITY}»"
    codesign --force --deep --sign "$IDENTITY" --options runtime "$APP"
else
    echo "⚠️  Сертификат «${IDENTITY}» не найден — подпись ad-hoc."
    echo "   Разрешение Input Monitoring будет слетать после каждой пересборки."
    echo "   См. Scripts/SIGNING.md"
    codesign --force --deep --sign - --options runtime "$APP"
fi

codesign --verify --strict "$APP"
echo "✓ Готово: $APP"

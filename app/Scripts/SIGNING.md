# Подпись сборки

macOS привязывает выданное разрешение Input Monitoring к подписи приложения.
При ad-hoc подписи (`codesign -s -`) идентификатор меняется на каждой сборке,
и разрешение приходится выдавать заново после каждой пересборки.

Поэтому один раз создаётся самоподписанный сертификат:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: `Sordio Dev`, Identity Type: `Self Signed Root`, Certificate Type: `Code Signing`.

Проверка: `security find-identity -v -p codesigning` содержит `Sordio Dev`.

Скрипт `build-app.sh` подписывает этим сертификатом, если он найден,
и откатывается на ad-hoc подпись с предупреждением, если нет.

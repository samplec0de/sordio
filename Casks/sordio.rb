# Файл создаётся скриптом Scripts/release.sh — править руками бессмысленно.
cask "sordio" do
  version "0.6.0"
  sha256 "c6836091c97e9141f6ace0650370d5428ddb06e03dc40aeef7172a9254641a5f"

  url "https://github.com/samplec0de/sordio/releases/download/v#{version}/Sordio-#{version}.dmg"
  name "Sordio"
  desc "Микрофон SaluteJazz глобальным хоткеем и плашкой поверх окон"
  homepage "https://github.com/samplec0de/sordio"

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

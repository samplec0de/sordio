import AppKit
import SordioCore

/// Иконка состояния в строке меню.
final class MenuBarController {
    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let overlayItem = NSMenuItem(title: "Плашка во время звонка", action: nil, keyEquivalent: "")

    private let flipperStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let flipperItem = NSMenuItem(title: "Flipper Zero", action: nil, keyEquivalent: "")
    private let flipperForgetItem = NSMenuItem(title: "Забыть Flipper", action: nil, keyEquivalent: "")

    var onToggleOverlay: (() -> Void)?
    var onToggleFlipper: (() -> Void)?
    var onForgetFlipper: (() -> Void)?
    var onOpenBluetoothSettings: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onRevealExtension: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        render(state: .noBridge)
    }

    private func buildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        overlayItem.action = #selector(toggleOverlay)
        overlayItem.target = self
        menu.addItem(overlayItem)

        flipperItem.action = #selector(toggleFlipper)
        flipperItem.target = self
        menu.addItem(flipperItem)

        // Строка состояния видна, только пока связь включена.
        flipperStatusItem.isHidden = true
        menu.addItem(flipperStatusItem)

        flipperForgetItem.action = #selector(forgetFlipper)
        flipperForgetItem.target = self
        flipperForgetItem.isHidden = true
        menu.addItem(flipperForgetItem)

        let permissions = NSMenuItem(title: "Разрешения системы…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        // Расширение лежит внутри бандла: так оно всегда той же версии, что и
        // приложение, а ставить его всё равно приходится вручную — в браузер
        // распакованной папкой.
        let reveal = NSMenuItem(title: "Показать папку расширения", action: #selector(revealExtension), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    /// Галочка отражает разрешение показывать плашку, а не её сиюминутную
    /// видимость: вне звонка плашка скрыта, но остаётся разрешённой.
    func setOverlayEnabled(_ enabled: Bool) {
        overlayItem.state = enabled ? .on : .off
    }

    /// Галочка — «связь с Flipper'ом включена», а не «Flipper подключён»:
    /// подключение описывает строка ниже.
    func render(flipper status: FlipperLink.Status) {
        flipperItem.state = status == .disabled ? .off : .on
        flipperStatusItem.isHidden = status == .disabled
        flipperForgetItem.isHidden = status == .disabled

        // Без доступа к Bluetooth строка становится кнопкой: открывает нужную панель.
        let needsSettings = status == .unauthorized
        flipperStatusItem.isEnabled = needsSettings
        flipperStatusItem.target = needsSettings ? self : nil
        flipperStatusItem.action = needsSettings ? #selector(openBluetoothSettings) : nil

        switch status {
        case .disabled: flipperStatusItem.title = ""
        case .bluetoothOff: flipperStatusItem.title = "Flipper: Bluetooth выключен"
        case .unauthorized: flipperStatusItem.title = "Flipper: нет доступа к Bluetooth — открыть настройки…"
        case .unsupported: flipperStatusItem.title = "Flipper: на этом Mac нет Bluetooth"
        case .searching: flipperStatusItem.title = "Flipper: ищу — запустите на нём Sordio Remote"
        case .connecting: flipperStatusItem.title = "Flipper: подключаюсь…"
        case .connected: flipperStatusItem.title = "Flipper: подключён"
        case .pairingFailed:
            flipperStatusItem.title = "Flipper: сопряжение не удалось — выключите и включите пункт"
        }
    }

    func render(state: OverlayState) {
        let symbol: String
        let description: String
        switch state {
        case .unmuted:
            symbol = "mic.fill"; description = "Микрофон включён"
        case .muted:
            symbol = "mic.slash.fill"; description = "Микрофон выключен"
        case .noBridge:
            symbol = "bolt.horizontal.circle"; description = "Нет связи с браузером"
        case .noCall:
            symbol = "mic.slash"; description = "Нет звонка"
        case .buttonNotFound:
            symbol = "questionmark.circle"; description = "Кнопка не найдена"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusLine.title = description
        item.button?.toolTip = description
    }

    @objc private func toggleOverlay() { onToggleOverlay?() }
    @objc private func toggleFlipper() { onToggleFlipper?() }
    @objc private func forgetFlipper() { onForgetFlipper?() }
    @objc private func openBluetoothSettings() { onOpenBluetoothSettings?() }
    @objc private func openPermissions() { onOpenPermissions?() }
    @objc private func revealExtension() { onRevealExtension?() }
    @objc private func quit() { onQuit?() }
}

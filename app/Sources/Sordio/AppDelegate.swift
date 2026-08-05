import AppKit
import SordioCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = MicStateStore()
    let overlayModel = OverlayModel()

    private var bridge: BridgeServer!
    private var hotkey: HotkeyMonitor!
    private var interpreter = PressInterpreter(holdThreshold: Preferences.shared.holdThreshold)
    private var menuBar: MenuBarController!
    private var overlay: OverlayPanel!
    private var timer: Timer?
    private var commandCounter = 0
    /// Исход прерванного удержания, который ждёт восстановления связи.
    private var deferredOutcome = DeferredOutcome()

    private var loudSince: TimeInterval?
    /// До какого момента плашку показываем вопреки отсутствию звонка.
    private var revealUntil: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
        menuBar.onOpenPermissions = {
            // Открываем ту панель, которой действительно не хватает; если
            // обе выданы — Мониторинг ввода как более частую причину проблем.
            if !HotkeyMonitor.hasAccessibilityPermission {
                HotkeyMonitor.openAccessibilitySettings()
            } else {
                HotkeyMonitor.openInputMonitoringSettings()
            }
        }
        menuBar.onRevealExtension = { Self.revealExtensionFolder() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        overlay = OverlayPanel(model: overlayModel) { [weak self] in
            self?.sendToggleIntent()
        }
        menuBar.setOverlayEnabled(Preferences.shared.overlayVisible)
        menuBar.onToggleOverlay = { [weak self] in
            guard let self else { return }
            // Переключаем именно разрешение показывать плашку, а не её текущую
            // видимость: вне звонка она скрыта сама, и ориентироваться на это
            // значило бы включать её ровно тогда, когда человек просит убрать.
            let enabled = !Preferences.shared.overlayVisible
            Preferences.shared.overlayVisible = enabled
            self.menuBar.setOverlayEnabled(enabled)
            self.syncOverlay()
        }

        store.onChange = { [weak self] state, pending in
            guard let self else { return }
            self.menuBar.render(state: state)
            self.overlayModel.state = state
            self.overlayModel.isPending = pending
            self.syncOverlay()
        }

        startBridge()
        startHotkey()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.store.tick(now: Date.timeIntervalSinceReferenceDate)
        }
    }

    /// Папка распакованного расширения внутри бандла. Открываем её в Finder,
    /// чтобы путь можно было просто перетащить в окно расширений браузера.
    private static func revealExtensionFolder() {
        guard let folder = Bundle.main.url(forResource: "extension", withExtension: nil) else {
            let alert = NSAlert()
            alert.messageText = "Расширения нет в этой сборке"
            alert.informativeText = """
                Так бывает у сборки для разработки: там расширение лежит \
                отдельно, в extension/dist рядом с исходниками.
                """
            alert.runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        bridge?.stop()
        timer?.invalidate()
    }

    // MARK: - уровень сигнала

    /// Порог, выше которого считаем, что человек говорит.
    private static let speakingThreshold: Float = 0.22
    /// Сколько нужно говорить в выключенный микрофон, чтобы предупредить.
    private static let speakingGrace: TimeInterval = 1.5

    // MARK: - видимость плашки

    /// Сколько плашка висит после нажатия хоткея вхолостую.
    private static let revealDuration: TimeInterval = 1.5

    /// Плашка — индикатор звонка, а не постоянный житель экрана: вне звонка
    /// она ничем не управляет и только мешает. Состояние без звонка всё равно
    /// видно по иконке в строке меню.
    private func syncOverlay() {
        guard Preferences.shared.overlayVisible else {
            overlay.hide()
            return
        }
        let controllable = store.overlay == .muted || store.overlay == .unmuted
        let revealed = Date.timeIntervalSinceReferenceDate < revealUntil
        if controllable || revealed {
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    /// Нажатие хоткея вне звонка не должно пропадать молча: плашка выходит на
    /// полторы секунды и подписью объясняет, почему ничего не произошло.
    private func revealTemporarily() {
        revealUntil = Date.timeIntervalSinceReferenceDate + Self.revealDuration
        syncOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDuration) { [weak self] in
            self?.syncOverlay()
        }
    }

    /// Уровень приходит из расширения: своего микрофона приложение не
    /// открывает вовсе — страница уже держит устройство ради звонка. Замер
    /// идёт по клону дорожки, поэтому предупреждение «вас не слышно» работает
    /// и тогда, когда SaluteJazz заглушил свою дорожку через `enabled = false`.
    private func handleLevel(_ level: Float) {
        overlayModel.level = level

        guard Preferences.shared.warnWhenSpeakingMuted, store.overlay == .muted else {
            loudSince = nil
            if overlayModel.speakingWhileMuted { overlayModel.speakingWhileMuted = false }
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        if level >= Self.speakingThreshold {
            if loudSince == nil { loudSince = now }
            let speaking = now - (loudSince ?? now) >= Self.speakingGrace
            if overlayModel.speakingWhileMuted != speaking {
                overlayModel.speakingWhileMuted = speaking
            }
        } else {
            loudSince = nil
            if overlayModel.speakingWhileMuted { overlayModel.speakingWhileMuted = false }
        }
    }

    // MARK: - мост

    private func startBridge() {
        bridge = BridgeServer(
            portRange: 8765...8775,
            pairing: PairingStore(extensionId: Preferences.shared.pairedExtensionId,
                                  secret: Preferences.shared.pairingSecret))

        // Диалог показывается строго по одному: за этим следит сам
        // `BridgeServer` — он не выдаёт второй запрос, пока висит первый.
        bridge.pairingRequest = { extensionId, reason, decide in
            let alert = NSAlert()
            switch reason {
            case .firstPairing:
                alert.messageText = "Разрешить подключение расширения?"
                alert.informativeText = """
                    Клиент «\(extensionId)» хочет управлять микрофоном в SaluteJazz.
                    Разрешайте, только если вы сами сейчас установили расширение Sordio.
                    """
            case .differentExtension(let paired):
                // Это не переустановка: идентификатор другой. Текст обязан
                // настораживать, а не выглядеть рутинным подтверждением.
                alert.alertStyle = .critical
                alert.messageText = "Подключается НЕ спаренное расширение"
                alert.informativeText = """
                    Раньше вы разрешили расширение «\(paired)», а сейчас подключиться \
                    пытается другой клиент — «\(extensionId)».
                    Так выглядит попытка подменить расширение: это может быть открытая \
                    в браузере страница, а не расширение Sordio.
                    Разрешайте, только если вы сами что-то переустановили прямо сейчас; \
                    иначе — отклоните.
                    """
            }
            alert.addButton(withTitle: "Разрешить")
            alert.addButton(withTitle: "Отклонить")
            decide(alert.runModal() == .alertFirstButtonReturn)
        }

        bridge.onPaired = { secret, extensionId in
            Preferences.shared.pairingSecret = secret
            Preferences.shared.pairedExtensionId = extensionId
        }

        bridge.onConnect = { [weak self] in
            guard let self else { return }
            self.store.bridgeConnected()
            // Удержание, прерванное обрывом связи, надо доиграть: иначе
            // микрофон в Джазе остаётся открытым навсегда (§6 спецификации).
            self.apply(self.deferredOutcome.take())
        }
        bridge.onDisconnect = { [weak self] in
            guard let self else { return }
            self.deferredOutcome.store(self.interpreter.cancel())
            // Уровень больше некому обновлять — индикатор обязан погаснуть,
            // а не замереть на последнем значении.
            self.handleLevel(0)
            self.store.bridgeDisconnected()
        }
        bridge.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .state(let context, let muted):
                self.store.apply(context: context, muted: muted)
            case .level(let level):
                self.handleLevel(level)
            case .hello:
                break
            }
        }

        do {
            try bridge.start()
            NSLog("Sordio: мост слушает порт \(bridge.port.map(String.init) ?? "?")")
        } catch {
            NSLog("Sordio: не удалось занять порт — \(error)")
        }
    }

    // MARK: - хоткей

    private func startHotkey() {
        hotkey = HotkeyMonitor(combo: Preferences.shared.combo)
        hotkey.onKeyDown = { [weak self] in self?.handleKeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.handleKeyUp() }

        // Диалог показываем только если перехват реально не завёлся — при
        // успехе `start()` пользователь ничего не должен видеть.
        guard !hotkey.start() else { return }

        let hasAccessibility = HotkeyMonitor.hasAccessibilityPermission
        let hasInputMonitoring = HotkeyMonitor.hasInputMonitoringPermission

        // Оба разрешения на месте, а tap всё равно не создался — это уже не
        // вопрос разрешений, и молчать об этом нельзя, но и просить снова
        // выдать то, что уже выдано, тоже нельзя: текст должен быть честным.
        guard hasAccessibility && hasInputMonitoring else {
            var missing: [String] = []
            if !hasAccessibility {
                missing.append("«Универсальный доступ» (Accessibility)")
                HotkeyMonitor.requestAccessibilityPermission()
            }
            if !hasInputMonitoring {
                missing.append("«Мониторинг ввода» (Input Monitoring)")
                HotkeyMonitor.requestInputMonitoringPermission()
            }

            let alert = NSAlert()
            alert.messageText = "Не хватает разрешений: \(missing.joined(separator: ", "))"
            alert.informativeText = """
                Без них глобальная горячая клавиша работать не может.
                Откройте «Конфиденциальность и безопасность» и включите Sordio \
                в перечисленных разделах, затем перезапустите приложение.
                """
            alert.addButton(withTitle: "Открыть настройки")
            alert.addButton(withTitle: "Позже")
            if alert.runModal() == .alertFirstButtonReturn {
                if !hasAccessibility { HotkeyMonitor.openAccessibilitySettings() }
                if !hasInputMonitoring { HotkeyMonitor.openInputMonitoringSettings() }
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Не удалось перехватить клавиатуру"
        alert.informativeText = """
            Разрешения «Универсальный доступ» и «Мониторинг ввода» выданы, но \
            системный перехват клавиатуры (CGEventTap) всё равно не создался. \
            Попробуйте перезапустить приложение; если не поможет — это баг, \
            подробности в Console.app (фильтр «Sordio»).
            """
        alert.addButton(withTitle: "Ок")
        alert.runModal()
    }

    private func handleKeyDown() {
        apply(interpreter.keyDown(at: Date.timeIntervalSinceReferenceDate,
                                  micState: store.knownState))
    }

    private func handleKeyUp() {
        apply(interpreter.keyUp(at: Date.timeIntervalSinceReferenceDate))
    }

    func sendToggleIntent() {
        // Клик по плашке синтезирует нажатие и отпускание одним мгновением.
        // Если хоткей сейчас физически зажат, синтетическое отпускание
        // завершило бы настоящее удержание: микрофон закрылся бы посреди
        // фразы, а реальное отпускание уже ничего бы не сделало.
        guard !interpreter.isPressed else { return }

        let now = Date.timeIntervalSinceReferenceDate
        apply(interpreter.keyDown(at: now, micState: store.knownState))
        apply(interpreter.keyUp(at: now))
    }

    private func apply(_ outcome: PressOutcome) {
        switch outcome {
        case .none:
            break
        case .setMuted(let muted):
            commandCounter += 1
            bridge.send(.setMuted(id: "c\(commandCounter)", muted: muted))
            store.commandSent(at: Date.timeIntervalSinceReferenceDate)
        case .flashUnavailable:
            revealTemporarily()
            overlay.flash()
        }
    }
}

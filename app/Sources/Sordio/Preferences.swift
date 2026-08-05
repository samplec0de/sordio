import Foundation
import ServiceManagement
import SordioCore

/// Настройки приложения. Тонкая обёртка над UserDefaults —
/// вся содержательная логика живёт в SordioCore.
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let combo = "hotkeyCombo"
        static let holdThreshold = "holdThreshold"
        static let overlayVisible = "overlayVisible"
        static let overlayX = "overlayOriginX"
        static let overlayY = "overlayOriginY"
        static let warnSpeakingMuted = "warnWhenSpeakingMuted"
        static let pairingSecret = "pairingSecret"
        static let pairedExtensionId = "pairedExtensionId"
    }

    private init() {
        defaults.register(defaults: [
            Key.holdThreshold: 0.35,
            Key.overlayVisible: true,
            Key.warnSpeakingMuted: true,
        ])
    }

    var combo: HotkeyCombo {
        get {
            guard let data = defaults.data(forKey: Key.combo),
                  let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data) else {
                return .default
            }
            return combo
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.combo) }
    }

    var holdThreshold: TimeInterval {
        get { defaults.double(forKey: Key.holdThreshold) }
        set { defaults.set(newValue, forKey: Key.holdThreshold) }
    }

    var overlayVisible: Bool {
        get { defaults.bool(forKey: Key.overlayVisible) }
        set { defaults.set(newValue, forKey: Key.overlayVisible) }
    }

    var overlayOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Key.overlayX) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: Key.overlayX),
                           y: defaults.double(forKey: Key.overlayY))
        }
        set {
            guard let newValue else { return }
            defaults.set(newValue.x, forKey: Key.overlayX)
            defaults.set(newValue.y, forKey: Key.overlayY)
        }
    }

    var warnWhenSpeakingMuted: Bool {
        get { defaults.bool(forKey: Key.warnSpeakingMuted) }
        set { defaults.set(newValue, forKey: Key.warnSpeakingMuted) }
    }

    /// Секрет, выданный расширению при спаривании.
    var pairingSecret: String? {
        get { defaults.string(forKey: Key.pairingSecret) }
        set { defaults.set(newValue, forKey: Key.pairingSecret) }
    }

    /// Идентификатор спаренного расширения. Хранится рядом с секретом:
    /// подключение принимается молча только при совпадении обоих (§10).
    var pairedExtensionId: String? {
        get { defaults.string(forKey: Key.pairedExtensionId) }
        set { defaults.set(newValue, forKey: Key.pairedExtensionId) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Sordio: не удалось изменить автозапуск — \(error)")
            }
        }
    }
}

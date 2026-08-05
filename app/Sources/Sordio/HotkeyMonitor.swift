import Foundation
import AppKit
import IOKit.hidsystem
import SordioCore

/// Глобальный перехват комбинации клавиш через CGEventTap.
///
/// Перехват именно поглощающий: иначе ⌃⌥A «протекал» бы в активное приложение.
///
/// `CGEventTap` требует ДВА независимых разрешения TCC: Accessibility
/// (`kTCCServiceAccessibility`, проверяется через `AXIsProcessTrusted`) даёт
/// право поглощать события, а Input Monitoring (`kTCCServiceListenEvent`,
/// проверяется через `IOHIDCheckAccess`) даёт сам поток клавиш. Не хватает
/// хотя бы одного — `CGEvent.tapCreate` тихо возвращает `nil`, без объяснений.
final class HotkeyMonitor {
    var combo: HotkeyCombo
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    // Логировать сюда keyCode/flags приходящих событий нельзя ни под каким
    // флагом: приложение стартует при входе в систему, имеет разрешение на
    // мониторинг ввода и пишет в общесистемный журнал, доступный Console.app.
    // Среди первых нажатий после входа вполне может оказаться пароль.

    init(combo: HotkeyCombo) {
        self.combo = combo
    }

    /// Разрешение «Универсальный доступ» (Accessibility).
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Разрешение «Мониторинг ввода» (Input Monitoring). Без него
    /// Accessibility в одиночку перехват не включает.
    static var hasInputMonitoringPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func requestInputMonitoringPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        // Диагностика в unified log: без неё выяснить, какого из двух
        // разрешений не хватает, можно было только раскопками в TCC.db.
        NSLog("Sordio: hotkey — accessibility=%@ inputMonitoring=%@ tap=%@",
              Self.hasAccessibilityPermission ? "granted" : "denied",
              Self.hasInputMonitoringPermission ? "granted" : "denied",
              createdTap != nil ? "created" : "nil")

        guard let tap = createdTap else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Система может отключить перехват при перегрузке — включаем обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue

        switch type {
        case .keyDown:
            guard combo.matches(keyCode: keyCode, flags: flags) else { break }
            // Автоповтор системы отбрасываем — иначе push-to-talk будет дёргаться.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat && !isDown {
                isDown = true
                DispatchQueue.main.async { self.onKeyDown?() }
            }
            return nil   // поглощаем

        case .keyUp:
            guard keyCode == combo.keyCode, isDown else { break }
            isDown = false
            DispatchQueue.main.async { self.onKeyUp?() }
            return nil

        case .flagsChanged:
            // Отпускание любого модификатора аккорда завершает удержание.
            if isDown && !combo.modifiersHeld(in: flags) {
                isDown = false
                DispatchQueue.main.async { self.onKeyUp?() }
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}

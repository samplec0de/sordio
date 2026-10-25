import Foundation

/// Решает, нужно ли сейчас держать связь с Flipper'ом.
///
/// Flipper держит одно Bluetooth-соединение, а Mac'ов у человека может быть
/// несколько. В режиме «только во время звонка» связь занимает тот компьютер,
/// где идёт звонок, и отпускает после его конца — Flipper свободен для другого.
///
/// Звонок кончается не только по-настоящему: страницу перезагрузили, расширение
/// переподключилось — и состояние на секунду «нет звонка». Рвать из-за этого
/// Bluetooth не стоит, поэтому отпускаем с задержкой. Время передаётся
/// аргументом, как в `PressInterpreter`.
public struct FlipperGate {
    public static let releaseDelay: TimeInterval = 15

    /// `nil` — ещё ни разу не спрашивали: запуск вне звонка отпускает сразу,
    /// ждать там нечего, связи ещё не было.
    private var holding: Bool?
    private var leftCallAt: TimeInterval?

    public init() {}

    public mutating func wantsConnection(onlyDuringCalls: Bool, inCall: Bool,
                                         now: TimeInterval) -> Bool {
        guard onlyDuringCalls else {
            holding = true
            leftCallAt = nil
            return true
        }
        if inCall {
            holding = true
            leftCallAt = nil
            return true
        }
        guard holding == true else {
            holding = false
            return false
        }
        let since = leftCallAt ?? now
        leftCallAt = since
        if now - since >= Self.releaseDelay {
            holding = false
            leftCallAt = nil
            return false
        }
        return true
    }
}

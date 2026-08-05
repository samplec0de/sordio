import Foundation

/// Подтверждённое состояние микрофона на момент нажатия.
public enum MicKnownState: Equatable {
    case muted
    case unmuted
    case unknown
}

/// Что приложение должно сделать в ответ на событие клавиши.
public enum PressOutcome: Equatable {
    case none
    case setMuted(Bool)
    /// Управлять нечем — подсветить плашку, чтобы нажатие не пропало молча.
    case flashUnavailable
}

/// Гибрид «короткое нажатие переключает, удержание — push-to-talk».
///
/// Время передаётся аргументом, а не читается из системных часов: это делает
/// поведение проверяемым тестами без ожиданий в реальном времени.
public struct PressInterpreter {
    public var holdThreshold: TimeInterval

    private var downAt: TimeInterval?
    private var stateAtDown: MicKnownState = .unknown

    public init(holdThreshold: TimeInterval = 0.35) {
        self.holdThreshold = holdThreshold
    }

    public var isPressed: Bool { downAt != nil }

    public mutating func keyDown(at time: TimeInterval, micState: MicKnownState) -> PressOutcome {
        // Повторные нажатия при удержании — автоповтор системы, их нужно отбросить,
        // иначе push-to-talk будет дёргаться.
        guard downAt == nil else { return .none }

        downAt = time
        stateAtDown = micState

        switch micState {
        case .unknown: return .flashUnavailable
        case .muted:   return .setMuted(false)
        case .unmuted: return .none
        }
    }

    public mutating func keyUp(at time: TimeInterval) -> PressOutcome {
        guard let downAt else { return .none }
        let held = time - downAt
        self.downAt = nil

        switch stateAtDown {
        case .unknown:
            return .none
        case .muted:
            // Короткое нажатие: микрофон уже открыт на keyDown, оставляем.
            // Удержание: возвращаем как было.
            return held < holdThreshold ? .none : .setMuted(true)
        case .unmuted:
            // Короткое нажатие: выключаем. Удержание: не трогаем.
            return held < holdThreshold ? .setMuted(true) : .none
        }
    }

    /// Аварийное завершение удержания (потеря связи, сон системы).
    public mutating func cancel() -> PressOutcome {
        guard downAt != nil else { return .none }
        downAt = nil
        return stateAtDown == .muted ? .setMuted(true) : .none
    }
}

/// Исход, который некому исполнить прямо сейчас, — придержать до восстановления связи.
///
/// Ровно один случай, но обидный: человек держит хоткей (микрофон открыт),
/// связь рвётся. `PressInterpreter.cancel()` честно говорит «верни как было»,
/// но отправлять некому — и если этот ответ выбросить, микрофон в Джазе
/// останется открытым навсегда: настоящее отпускание клавиши уже ничего не
/// сделает, состояние нажатия обнулено (§6 спецификации).
public struct DeferredOutcome: Equatable {
    private var stored: PressOutcome?

    public init() {}

    public var isEmpty: Bool { stored == nil }

    /// `.none` придерживать незачем — отправлять всё равно нечего.
    public mutating func store(_ outcome: PressOutcome) {
        guard outcome != .none else { return }
        stored = outcome
    }

    /// Забрать отложенный исход, освободив место. Повторный вызов вернёт `.none`.
    public mutating func take() -> PressOutcome {
        defer { stored = nil }
        return stored ?? .none
    }

    public mutating func clear() {
        stored = nil
    }
}

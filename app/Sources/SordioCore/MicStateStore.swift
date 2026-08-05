import Foundation

/// Что показывает плашка. «Непонятно» — такое же полноправное состояние,
/// как и остальные: плашка никогда не притворяется работающей.
public enum OverlayState: Equatable {
    case unmuted
    case muted
    case noBridge
    case noCall
    case buttonNotFound
}

/// Единственный источник истины о состоянии микрофона.
///
/// Хранит только **подтверждённое** состояние DOM. Отправленная команда
/// поднимает флаг ожидания, но не меняет состояние.
public final class MicStateStore {
    public static let confirmationTimeout: TimeInterval = 0.8

    public private(set) var overlay: OverlayState = .noBridge
    public private(set) var isPending: Bool = false

    public var onChange: ((OverlayState, Bool) -> Void)?

    private var commandSentAt: TimeInterval?

    public init() {}

    public var knownState: MicKnownState {
        switch overlay {
        case .muted: return .muted
        case .unmuted: return .unmuted
        case .noBridge, .noCall, .buttonNotFound: return .unknown
        }
    }

    public func bridgeConnected() {
        set(overlay: .noCall, pending: false)
    }

    public func bridgeDisconnected() {
        commandSentAt = nil
        set(overlay: .noBridge, pending: false)
    }

    public func apply(context: MicContext, muted: Bool?) {
        let next: OverlayState
        switch context {
        case .noCall:
            next = .noCall
        case .buttonNotFound:
            next = .buttonNotFound
        case .inCall, .preCall:
            guard let muted else {
                next = .buttonNotFound
                break
            }
            next = muted ? .muted : .unmuted
        }
        commandSentAt = nil
        set(overlay: next, pending: false)
    }

    public func commandSent(at time: TimeInterval) {
        commandSentAt = time
        set(overlay: overlay, pending: true)
    }

    /// Вызывается таймером приложения. Снимает флаг ожидания по таймауту,
    /// не трогая подтверждённое состояние.
    public func tick(now: TimeInterval) {
        guard let sentAt = commandSentAt else { return }
        guard now - sentAt >= Self.confirmationTimeout else { return }
        commandSentAt = nil
        set(overlay: overlay, pending: false)
    }

    private func set(overlay newOverlay: OverlayState, pending newPending: Bool) {
        guard newOverlay != overlay || newPending != isPending else { return }
        overlay = newOverlay
        isPending = newPending
        onChange?(overlay, isPending)
    }
}

import Foundation

/// Нажатие кнопки OK на Flipper Zero.
public enum FlipperEvent: Equatable {
    case down
    case up
}

/// Протокол между Sordio и приложением Sordio Remote на Flipper Zero.
///
/// Идёт поверх штатного Bluetooth-serial профиля Flipper'а, по одному байту на
/// сообщение. Значения продублированы в `flipper/sordio_remote/protocol.h`;
/// `FlipperProtocolTests` сверяет обе половины, потому что расхождение
/// выглядело бы как «кнопка иногда не работает» и ловилось бы только на железе.
public enum FlipperProtocol {
    /// Сервис и характеристики штатного serial-профиля Flipper'а — тот же,
    /// что использует его мобильное приложение. Названия — со стороны Flipper'а.
    public static let serviceUUID = "8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000"
    /// Flipper → Mac (indicate).
    public static let eventsUUID = "19ed82ae-ed21-4c9d-4145-228e61fe0000"
    /// Mac → Flipper (write).
    public static let stateUUID = "19ed82ae-ed21-4c9d-4145-228e62fe0000"

    static let down: UInt8 = 0xA1
    static let up: UInt8 = 0xA2

    /// Одна индикация может нести несколько байт; чужие байты пропускаются —
    /// новая версия приложения на Flipper'е не должна ломать старую Sordio.
    public static func decode(_ data: Data) -> [FlipperEvent] {
        data.compactMap { byte in
            switch byte {
            case down: return .down
            case up: return .up
            default: return nil
            }
        }
    }

    /// Подтверждённое состояние микрофона — то, что Flipper показывает на экране
    /// и чем различает вибрации.
    public static func encode(_ state: OverlayState) -> UInt8 {
        switch state {
        case .unmuted: return 0x01
        case .muted: return 0x02
        case .noCall: return 0x03
        case .noBridge: return 0x04
        case .buttonNotFound: return 0x05
        }
    }
}

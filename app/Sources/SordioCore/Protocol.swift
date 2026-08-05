import Foundation

/// Что расширение видит на странице SaluteJazz.
public enum MicContext: String, Codable, Equatable {
    case inCall = "in-call"
    case preCall = "pre-call"
    case noCall = "no-call"
    case buttonNotFound = "button-not-found"
}

/// Расширение → приложение.
///
/// Подтверждения команды в протоколе нет намеренно: источник истины один —
/// состояние страницы (§4.1), и оно приезжает обычным `state`. Отдельный `ack`
/// был бы вторым источником истины, который нечем сверять.
public enum InboundMessage: Equatable {
    case hello(extensionId: String, secret: String?)
    case state(context: MicContext, muted: Bool?)
    /// Уровень сигнала, 0…1. Считает расширение по клону аудиодорожки
    /// страницы — своего микрофона приложение не открывает.
    case level(Float)
}

/// Приложение → расширение.
public enum OutboundMessage: Equatable {
    case welcome
    /// Спаривание состоялось — клиент должен сохранить секрет и предъявлять его дальше.
    case paired(secret: String)
    case setMuted(id: String, muted: Bool)
}

public enum ProtocolError: Error, Equatable {
    case malformed(String)
    case unsupportedVersion(Int)
}

public enum MessageCodec {
    public static let version = 1

    public static func decode(_ data: Data) throws -> InboundMessage {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let obj = object as? [String: Any] else {
            throw ProtocolError.malformed("не JSON-объект")
        }
        let v = obj["v"] as? Int ?? 0
        guard v == version else { throw ProtocolError.unsupportedVersion(v) }

        switch obj["type"] as? String {
        case "hello":
            guard let id = obj["extensionId"] as? String else {
                throw ProtocolError.malformed("hello без extensionId")
            }
            return .hello(extensionId: id, secret: obj["secret"] as? String)
        case "state":
            guard let raw = obj["context"] as? String,
                  let context = MicContext(rawValue: raw) else {
                throw ProtocolError.malformed("неизвестный context")
            }
            return .state(context: context, muted: obj["muted"] as? Bool)
        case "level":
            // `as? Double` на стороне JSONSerialization принимает и целое 0,
            // и 0.42 — обе формы законны, JSON чисел не различает.
            guard let raw = obj["level"] as? Double, raw.isFinite else {
                throw ProtocolError.malformed("level не число")
            }
            return .level(Float(min(1, max(0, raw))))
        default:
            throw ProtocolError.malformed("неизвестный type")
        }
    }

    public static func encode(_ message: OutboundMessage) -> Data {
        var obj: [String: Any] = ["v": version]
        switch message {
        case .welcome:
            obj["type"] = "welcome"
        case .paired(let secret):
            obj["type"] = "paired"
            obj["secret"] = secret
        case .setMuted(let id, let muted):
            obj["type"] = "command"
            obj["action"] = "setMuted"
            obj["id"] = id
            obj["muted"] = muted
        }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

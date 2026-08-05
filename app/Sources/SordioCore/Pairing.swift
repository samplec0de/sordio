import Foundation

/// Почему у пользователя спрашивают подтверждение.
///
/// Различие принципиально для текста диалога: «первое подключение» и
/// «подключается не то расширение, с которым вы спаривались» — совершенно
/// разные новости, и второе должно настораживать.
public enum ApprovalReason: Equatable {
    /// Спаривания ещё не было (или расширение переустановили — id тот же).
    case firstPairing
    /// Идентификатор не совпал с сохранённым: это другой клиент.
    case differentExtension(paired: String)
}

public enum PairingDecision: Equatable {
    /// Идентификатор и секрет совпали — пускаем молча.
    case accept
    /// Нужно спросить пользователя.
    case needsApproval(id: String, reason: ApprovalReason)
    /// Мусор, до пользователя доводить нечего.
    case reject(String)
}

/// Кто имеет право управлять микрофоном.
///
/// `Network.framework` не показывает серверу заголовок `Origin`, поэтому клиент
/// подтверждается парой «идентификатор + секрет, выданный при спаривании».
/// Это сознательный компромисс — см. §8 спецификации.
public struct PairingStore: Equatable {
    /// Идентификатор спаренного расширения. nil — спаривания ещё не было.
    public var extensionId: String?
    public var secret: String?

    public init(extensionId: String? = nil, secret: String?) {
        self.extensionId = extensionId
        self.secret = secret
    }

    public static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // Молча выдать предсказуемый секрет (нулевые байты) хуже, чем упасть:
        // это дыра в безопасности спаривания, а не мелкая ошибка.
        guard status == errSecSuccess else {
            preconditionFailure("SecRandomCopyBytes завершился с ошибкой: OSStatus \(status)")
        }
        return Data(bytes).base64EncodedString()
    }

    /// Идентификатор расширения Chrome — ровно 32 строчные буквы `a`…`p`
    /// (base16 по алфавиту a–p от хеша ключа расширения). Всё остальное —
    /// не идентификатор, а произвольная строка от того, кто подключился.
    ///
    /// Проверка нужна не для красоты: строку показывают в модальном диалоге,
    /// единственная защита которого — внимательность человека. В свободные
    /// 64 символа помещается перевод строки и текст вида «Это системное окно,
    /// нажмите Разрешить».
    public static func isValidExtensionId(_ id: String) -> Bool {
        guard id.count == 32 else { return false }
        return id.unicodeScalars.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    public func evaluate(extensionId: String, secret: String?) -> PairingDecision {
        guard Self.isValidExtensionId(extensionId) else {
            return .reject("некорректный идентификатор клиента")
        }

        guard let pairedId = self.extensionId else {
            // Спаривания ещё не было — обычный первый запуск.
            return .needsApproval(id: extensionId, reason: .firstPairing)
        }

        guard pairedId == extensionId else {
            // Подключается не то расширение, которое было спарено. Секрет тут
            // не проверяем вовсе: даже совпавший секрет от чужого id — повод
            // остановиться и спросить человека отдельным текстом.
            return .needsApproval(id: extensionId,
                                  reason: .differentExtension(paired: pairedId))
        }

        if let stored = self.secret, let secret, secret == stored {
            return .accept
        }

        // Идентификатор тот же, а секрет потерялся: расширение переустановили
        // или почистили chrome.storage. Обычная ситуация — просто спрашиваем.
        return .needsApproval(id: extensionId, reason: .firstPairing)
    }
}

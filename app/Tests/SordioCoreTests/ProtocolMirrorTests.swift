import XCTest
@testable import SordioCore

/// Зеркало протокола: обе половины (Swift и TypeScript) обязаны одинаково
/// понимать один и тот же набор эталонных строк.
///
/// Протокол объявлен дважды, а половины тестируются порознь — расхождение
/// между ними не поймал бы ни один существующий тест. Парный тест лежит в
/// `extension/tests/protocolMirror.test.ts` и читает тот же файл.
final class ProtocolMirrorTests: XCTestCase {

    /// Файл фикстур лежит вне пакета, поэтому путь считается от исходника:
    /// объявлять его ресурсом тест-таргета пришлось бы копией внутрь Tests/,
    /// а копия ровно так же расходится с оригиналом, как две половины протокола.
    private static let fixturesURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // .../app/Tests/SordioCoreTests/ProtocolMirrorTests.swift → корень репозитория
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("shared/protocol-fixtures.json")
    }()

    private func fixtures(_ key: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.fixturesURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(root[key] as? [[String: Any]], "в фикстурах нет раздела \(key)")
        XCTAssertFalse(list.isEmpty, "раздел \(key) пуст — зеркало ничего не проверяет")
        return list
    }

    func testFixtureVersionMatchesCodec() throws {
        let data = try Data(contentsOf: Self.fixturesURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, MessageCodec.version)
    }

    /// Всё, что расширение отправляет, приложение обязано разобрать.
    func testDecodesEveryExtensionToAppFixture() throws {
        for fixture in try fixtures("extensionToApp") {
            let name = fixture["name"] as? String ?? "?"
            let json = try XCTUnwrap(fixture["json"] as? String, name)
            let expected = try inbound(from: XCTUnwrap(fixture["message"] as? [String: Any], name))

            XCTAssertEqual(try MessageCodec.decode(Data(json.utf8)), expected, name)
        }
    }

    /// Всё, что приложение отправляет, должно совпадать со строкой, которую
    /// на другой стороне разбирает `parseInbound`.
    func testEncodesEveryAppToExtensionFixture() throws {
        for fixture in try fixtures("appToExtension") {
            let name = fixture["name"] as? String ?? "?"
            let json = try XCTUnwrap(fixture["json"] as? String, name)
            let message = try outbound(from: XCTUnwrap(fixture["message"] as? [String: Any], name))

            XCTAssertEqual(String(decoding: MessageCodec.encode(message), as: UTF8.self), json, name)
        }
    }

    // MARK: - сборка сообщений из фикстуры

    private func inbound(from object: [String: Any]) throws -> InboundMessage {
        switch object["type"] as? String {
        case "hello":
            return .hello(extensionId: try XCTUnwrap(object["extensionId"] as? String),
                          secret: object["secret"] as? String)
        case "state":
            let raw = try XCTUnwrap(object["context"] as? String)
            return .state(context: try XCTUnwrap(MicContext(rawValue: raw)),
                          muted: object["muted"] as? Bool)
        case "level":
            return .level(Float(try XCTUnwrap(object["level"] as? Double)))
        default:
            throw XCTSkip("неизвестный тип в фикстуре: \(object["type"] ?? "nil")")
        }
    }

    private func outbound(from object: [String: Any]) throws -> OutboundMessage {
        switch object["type"] as? String {
        case "welcome":
            return .welcome
        case "paired":
            return .paired(secret: try XCTUnwrap(object["secret"] as? String))
        case "command":
            XCTAssertEqual(object["action"] as? String, "setMuted")
            return .setMuted(id: try XCTUnwrap(object["id"] as? String),
                             muted: try XCTUnwrap(object["muted"] as? Bool))
        default:
            throw XCTSkip("неизвестный тип в фикстуре: \(object["type"] ?? "nil")")
        }
    }
}

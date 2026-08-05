import XCTest
@testable import SordioCore

final class ProtocolTests: XCTestCase {

    private func decode(_ json: String) throws -> InboundMessage {
        try MessageCodec.decode(Data(json.utf8))
    }

    func testDecodesStateInCall() throws {
        let msg = try decode(#"{"v":1,"type":"state","context":"in-call","muted":false}"#)
        XCTAssertEqual(msg, .state(context: .inCall, muted: false))
    }

    func testDecodesStateWithoutMuted() throws {
        let msg = try decode(#"{"v":1,"type":"state","context":"no-call"}"#)
        XCTAssertEqual(msg, .state(context: .noCall, muted: nil))
    }

    func testDecodesHelloWithoutSecret() throws {
        XCTAssertEqual(try decode(#"{"v":1,"type":"hello","extensionId":"abc"}"#),
                       .hello(extensionId: "abc", secret: nil))
    }

    func testDecodesHelloWithSecret() throws {
        XCTAssertEqual(try decode(#"{"v":1,"type":"hello","extensionId":"abc","secret":"s3"}"#),
                       .hello(extensionId: "abc", secret: "s3"))
    }

    func testDecodesLevel() throws {
        let json = #"{"level":0.42,"type":"level","v":1}"#
        XCTAssertEqual(try MessageCodec.decode(Data(json.utf8)), .level(0.42))
    }

    /// JSON не различает 0 и 0.0 — обе записи законны и обе обязаны разобраться.
    func testDecodesIntegerLevel() throws {
        let json = #"{"level":1,"type":"level","v":1}"#
        XCTAssertEqual(try MessageCodec.decode(Data(json.utf8)), .level(1))
    }

    /// Значение считает страница, а она может прислать что угодно.
    func testClampsLevelOutOfRange() throws {
        let high = #"{"level":7,"type":"level","v":1}"#
        let low = #"{"level":-3,"type":"level","v":1}"#
        XCTAssertEqual(try MessageCodec.decode(Data(high.utf8)), .level(1))
        XCTAssertEqual(try MessageCodec.decode(Data(low.utf8)), .level(0))
    }

    func testRejectsLevelWithoutNumber() {
        let json = #"{"level":"громко","type":"level","v":1}"#
        XCTAssertThrowsError(try MessageCodec.decode(Data(json.utf8)))
    }

    func testRejectsAckAsUnknownType() {
        // Подтверждения команд в протоколе нет: единственный источник истины —
        // входящий `state`. Сообщение `ack` должно отвергаться как чужое.
        XCTAssertThrowsError(try decode(#"{"v":1,"type":"ack","id":"c7","ok":true}"#))
    }

    func testRejectsWrongVersion() {
        XCTAssertThrowsError(try decode(#"{"v":2,"type":"state","context":"no-call"}"#)) { error in
            XCTAssertEqual(error as? ProtocolError, .unsupportedVersion(2))
        }
    }

    func testRejectsUnknownContext() {
        XCTAssertThrowsError(try decode(#"{"v":1,"type":"state","context":"levitating"}"#))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MessageCodec.decode(Data("not json".utf8)))
    }

    func testEncodesSetMuted() throws {
        let data = MessageCodec.encode(.setMuted(id: "c7", muted: true))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["type"] as? String, "command")
        XCTAssertEqual(obj["action"] as? String, "setMuted")
        XCTAssertEqual(obj["id"] as? String, "c7")
        XCTAssertEqual(obj["muted"] as? Bool, true)
    }

    func testEncodesWelcome() throws {
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: MessageCodec.encode(.welcome)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "welcome")
    }

    func testEncodesPairedWithSecret() throws {
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: MessageCodec.encode(.paired(secret: "s3"))) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "paired")
        XCTAssertEqual(obj["secret"] as? String, "s3")
    }
}

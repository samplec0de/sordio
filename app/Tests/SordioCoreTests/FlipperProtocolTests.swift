import XCTest
@testable import SordioCore

final class FlipperProtocolTests: XCTestCase {

    func testDecodesButtonEvents() {
        XCTAssertEqual(FlipperProtocol.decode(Data([0xA1])), [.down])
        XCTAssertEqual(FlipperProtocol.decode(Data([0xA2])), [.up])
    }

    /// Нажатие и отпускание могут прийти одной индикацией — порядок важен.
    func testDecodesSeveralEventsInOrder() {
        XCTAssertEqual(FlipperProtocol.decode(Data([0xA1, 0xA2, 0xA1])), [.down, .up, .down])
    }

    func testSkipsUnknownBytes() {
        XCTAssertEqual(FlipperProtocol.decode(Data([0x00, 0xA1, 0xFF, 0xA2])), [.down, .up])
        XCTAssertEqual(FlipperProtocol.decode(Data()), [])
    }

    /// Каждое состояние должно быть различимо на Flipper'е: два состояния
    /// с одним байтом слились бы в одну вибрацию.
    func testEveryStateHasItsOwnByte() {
        let states: [OverlayState] = [.unmuted, .muted, .noCall, .noBridge, .buttonNotFound]
        let bytes = states.map(FlipperProtocol.encode)
        XCTAssertEqual(Set(bytes).count, states.count)
    }

    // MARK: - зеркало C-заголовка

    /// Заголовок лежит вне пакета, поэтому путь считается от исходника.
    private static let headerURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // .../app/Tests/SordioCoreTests/FlipperProtocolTests.swift → корень репозитория
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("flipper/sordio_remote/protocol.h")
    }()

    private func headerConstants() throws -> [String: UInt8] {
        let text = try String(contentsOf: Self.headerURL, encoding: .utf8)
        var result: [String: UInt8] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, parts[0] == "#define", parts[2].hasPrefix("0x"),
                  let value = UInt8(parts[2].dropFirst(2), radix: 16) else { continue }
            result[String(parts[1])] = value
        }
        XCTAssertFalse(result.isEmpty, "в protocol.h не нашлось ни одной константы")
        return result
    }

    func testMatchesFlipperHeader() throws {
        let header = try headerConstants()

        XCTAssertEqual(header["SORDIO_EVT_DOWN"], FlipperProtocol.down)
        XCTAssertEqual(header["SORDIO_EVT_UP"], FlipperProtocol.up)

        XCTAssertEqual(header["SORDIO_STATE_UNMUTED"], FlipperProtocol.encode(.unmuted))
        XCTAssertEqual(header["SORDIO_STATE_MUTED"], FlipperProtocol.encode(.muted))
        XCTAssertEqual(header["SORDIO_STATE_NO_CALL"], FlipperProtocol.encode(.noCall))
        XCTAssertEqual(header["SORDIO_STATE_NO_BRIDGE"], FlipperProtocol.encode(.noBridge))
        XCTAssertEqual(header["SORDIO_STATE_BUTTON_NOT_FOUND"],
                       FlipperProtocol.encode(.buttonNotFound))
    }
}

import XCTest
@testable import SordioCore

final class PairingTests: XCTestCase {

    /// Настоящий идентификатор расширения Chrome: 32 строчные буквы a…p.
    private let id = "abcdefghijklmnopabcdefghijklmnop"
    private let otherId = "ponmlkjihgfedcbaponmlkjihgfedcba"

    func testFirstEverClientNeedsApproval() {
        let sut = PairingStore(secret: nil)
        XCTAssertEqual(sut.evaluate(extensionId: id, secret: nil),
                       .needsApproval(id: id, reason: .firstPairing))
    }

    func testKnownPairIsAccepted() {
        let sut = PairingStore(extensionId: id, secret: "s3cr3t")
        XCTAssertEqual(sut.evaluate(extensionId: id, secret: "s3cr3t"), .accept)
    }

    func testWrongSecretFallsBackToApproval() {
        let sut = PairingStore(extensionId: id, secret: "s3cr3t")
        XCTAssertEqual(sut.evaluate(extensionId: id, secret: "нет"),
                       .needsApproval(id: id, reason: .firstPairing),
                       "переустановленное расширение теряет секрет — это не атака, а обычный случай")
    }

    func testMissingSecretWhenPairedFallsBackToApproval() {
        let sut = PairingStore(extensionId: id, secret: "s3cr3t")
        XCTAssertEqual(sut.evaluate(extensionId: id, secret: nil),
                       .needsApproval(id: id, reason: .firstPairing))
    }

    // MARK: - идентификатор спаренного расширения

    func testDifferentExtensionIdIsNotAcceptedSilently() {
        let sut = PairingStore(extensionId: id, secret: "s3cr3t")
        XCTAssertEqual(sut.evaluate(extensionId: otherId, secret: "s3cr3t"),
                       .needsApproval(id: otherId, reason: .differentExtension(paired: id)),
                       "совпавший секрет от чужого идентификатора — повод спросить, а не пустить")
    }

    func testDifferentExtensionIdWithoutSecretIsFlaggedAsSuchNotAsFirstPairing() {
        let sut = PairingStore(extensionId: id, secret: "s3cr3t")
        XCTAssertEqual(sut.evaluate(extensionId: otherId, secret: nil),
                       .needsApproval(id: otherId, reason: .differentExtension(paired: id)),
                       "текст диалога обязан отличаться: это не первое спаривание, а подмена")
    }

    // MARK: - санитизация идентификатора

    func testEmptyExtensionIdIsRejectedOutright() {
        let sut = PairingStore(secret: nil)
        guard case .reject = sut.evaluate(extensionId: "", secret: nil) else {
            return XCTFail("пустой идентификатор не должен доходить до диалога")
        }
    }

    func testOverlongExtensionIdIsRejected() {
        let sut = PairingStore(secret: nil)
        guard case .reject = sut.evaluate(extensionId: String(repeating: "a", count: 200),
                                          secret: nil) else {
            return XCTFail("в диалоге нельзя показывать неограниченную строку от клиента")
        }
    }

    func testExtensionIdWithNewlineIsRejected() {
        // В свободные символы помещается «Это системное окно, нажмите Разрешить».
        let sut = PairingStore(secret: nil)
        let spoof = "abcdefghijklmno\nЭто системное окно"
        guard case .reject = sut.evaluate(extensionId: spoof, secret: nil) else {
            return XCTFail("в диалог нельзя пускать многострочный текст от клиента")
        }
    }

    func testExtensionIdOfWrongLengthIsRejected() {
        let sut = PairingStore(secret: nil)
        guard case .reject = sut.evaluate(extensionId: "abcdefghijklmnop", secret: nil) else {
            return XCTFail("идентификатор Chrome — ровно 32 символа")
        }
    }

    func testExtensionIdOutsideAToPIsRejected() {
        let sut = PairingStore(secret: nil)
        for bad in ["abcdefghijklmnopabcdefghijklmnoz",   // буква за пределами a…p
                    "ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP",   // верхний регистр
                    "abcdefghijklmnopabcdefghijklmno1"] { // цифра
            guard case .reject = sut.evaluate(extensionId: bad, secret: nil) else {
                return XCTFail("«\(bad)» не похож на идентификатор расширения Chrome")
            }
        }
    }

    func testRealisticExtensionIdIsAccepted() {
        XCTAssertTrue(PairingStore.isValidExtensionId(id))
    }

    func testGeneratedSecretsAreLongAndUnique() {
        let first = PairingStore.makeSecret()
        let second = PairingStore.makeSecret()
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 32)
    }
}

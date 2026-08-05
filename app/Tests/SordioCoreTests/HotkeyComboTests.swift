import XCTest
@testable import SordioCore

final class HotkeyComboTests: XCTestCase {

    private let control: UInt64 = 0x40000   // kCGEventFlagMaskControl
    private let option: UInt64  = 0x80000   // kCGEventFlagMaskAlternate
    private let command: UInt64 = 0x100000  // kCGEventFlagMaskCommand
    private let shift: UInt64   = 0x20000   // kCGEventFlagMaskShift

    func testDefaultIsControlOptionA() {
        let sut = HotkeyCombo.default
        XCTAssertEqual(sut.keyCode, 0)          // 0 = клавиша A
        XCTAssertTrue(sut.control)
        XCTAssertTrue(sut.option)
        XCTAssertFalse(sut.command)
        XCTAssertFalse(sut.shift)
        XCTAssertEqual(sut.displayString, "⌃⌥A")
    }

    func testDisplayStringOrdersModifiersLikeMacOS() {
        let sut = HotkeyCombo(keyCode: 1, control: true, option: true, command: true, shift: true)
        XCTAssertEqual(sut.displayString, "⌃⌥⇧⌘S")
    }

    func testMatchesExactModifierSet() {
        let sut = HotkeyCombo.default
        XCTAssertTrue(sut.matches(keyCode: 0, flags: control | option))
        XCTAssertFalse(sut.matches(keyCode: 0, flags: control))
        XCTAssertFalse(sut.matches(keyCode: 0, flags: control | option | command),
                       "лишний модификатор — это другая комбинация")
        XCTAssertFalse(sut.matches(keyCode: 1, flags: control | option))
    }

    func testIgnoresIrrelevantFlagBits() {
        // Caps Lock и признак «функциональная клавиша» не должны ломать совпадение.
        let noise: UInt64 = 0x10000 | 0x800000
        XCTAssertTrue(HotkeyCombo.default.matches(keyCode: 0, flags: control | option | noise))
    }

    func testModifiersHeldDetectsReleaseOfAnyModifier() {
        let sut = HotkeyCombo.default
        XCTAssertTrue(sut.modifiersHeld(in: control | option))
        XCTAssertFalse(sut.modifiersHeld(in: control),
                       "отпускание любой клавиши аккорда завершает push-to-talk")
        XCTAssertFalse(sut.modifiersHeld(in: 0))
    }

    func testCodableRoundTrip() throws {
        let original = HotkeyCombo(keyCode: 49, control: false, option: true, command: true, shift: false)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyCombo.self, from: data), original)
    }

    func testDisplayStringForNamedKeys() {
        XCTAssertEqual(HotkeyCombo(keyCode: 49, control: true, option: false, command: false, shift: false).displayString, "⌃Space")
        XCTAssertEqual(HotkeyCombo(keyCode: 96, control: false, option: false, command: false, shift: false).displayString, "F5")
    }
}

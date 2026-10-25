import XCTest
@testable import SordioCore

final class FlipperGateTests: XCTestCase {

    private func wants(_ gate: inout FlipperGate, onlyDuringCalls: Bool = true,
                       inCall: Bool, at now: TimeInterval) -> Bool {
        gate.wantsConnection(onlyDuringCalls: onlyDuringCalls, inCall: inCall, now: now)
    }

    func testAlwaysModeKeepsConnectionOutsideCalls() {
        var gate = FlipperGate()
        XCTAssertTrue(wants(&gate, onlyDuringCalls: false, inCall: false, at: 0))
        XCTAssertTrue(wants(&gate, onlyDuringCalls: false, inCall: false, at: 1000))
    }

    /// Запуск вне звонка — связи ещё не было, держать нечего.
    func testLaunchOutsideCallReleasesImmediately() {
        var gate = FlipperGate()
        XCTAssertFalse(wants(&gate, inCall: false, at: 0))
    }

    func testCallTakesConnection() {
        var gate = FlipperGate()
        XCTAssertFalse(wants(&gate, inCall: false, at: 0))
        XCTAssertTrue(wants(&gate, inCall: true, at: 1))
    }

    func testReleasesOnlyAfterDelayOnceCallEnds() {
        var gate = FlipperGate()
        XCTAssertTrue(wants(&gate, inCall: true, at: 0))
        XCTAssertTrue(wants(&gate, inCall: false, at: 10))
        XCTAssertTrue(wants(&gate, inCall: false, at: 10 + FlipperGate.releaseDelay - 0.1))
        XCTAssertFalse(wants(&gate, inCall: false, at: 10 + FlipperGate.releaseDelay))
    }

    /// Страница мигнула «нет звонка» и вернулась — Bluetooth рвать не нужно,
    /// а следующий отсчёт идёт заново.
    func testBriefDropoutDoesNotReleaseAndRestartsCountdown() {
        var gate = FlipperGate()
        XCTAssertTrue(wants(&gate, inCall: true, at: 0))
        XCTAssertTrue(wants(&gate, inCall: false, at: 5))
        XCTAssertTrue(wants(&gate, inCall: true, at: 8))
        XCTAssertTrue(wants(&gate, inCall: false, at: 9))
        XCTAssertTrue(wants(&gate, inCall: false, at: 9 + FlipperGate.releaseDelay - 0.1))
        XCTAssertFalse(wants(&gate, inCall: false, at: 9 + FlipperGate.releaseDelay))
    }

    func testReleasedStaysReleasedUntilNextCall() {
        var gate = FlipperGate()
        XCTAssertTrue(wants(&gate, inCall: true, at: 0))
        XCTAssertTrue(wants(&gate, inCall: false, at: 1))
        XCTAssertFalse(wants(&gate, inCall: false, at: 1 + FlipperGate.releaseDelay))
        XCTAssertFalse(wants(&gate, inCall: false, at: 500))
        XCTAssertTrue(wants(&gate, inCall: true, at: 501))
    }

    /// Выключили режим посреди отсчёта — связь нужна снова, без остатков таймера.
    func testSwitchingToAlwaysModeCancelsCountdown() {
        var gate = FlipperGate()
        XCTAssertTrue(wants(&gate, inCall: true, at: 0))
        XCTAssertTrue(wants(&gate, inCall: false, at: 1))
        XCTAssertTrue(wants(&gate, onlyDuringCalls: false, inCall: false, at: 5))
        XCTAssertTrue(wants(&gate, inCall: false, at: 6))
        XCTAssertFalse(wants(&gate, inCall: false, at: 6 + FlipperGate.releaseDelay))
    }
}

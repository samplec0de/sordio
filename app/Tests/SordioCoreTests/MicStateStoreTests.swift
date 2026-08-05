import XCTest
@testable import SordioCore

final class MicStateStoreTests: XCTestCase {

    func testStartsWithoutBridge() {
        let sut = MicStateStore()
        XCTAssertEqual(sut.overlay, .noBridge)
        XCTAssertEqual(sut.knownState, .unknown)
    }

    func testConnectedButNoCall() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .noCall, muted: nil)
        XCTAssertEqual(sut.overlay, .noCall)
        XCTAssertEqual(sut.knownState, .unknown)
    }

    func testInCallMuted() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .inCall, muted: true)
        XCTAssertEqual(sut.overlay, .muted)
        XCTAssertEqual(sut.knownState, .muted)
    }

    func testPreCallUnmutedIsControllableToo() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .preCall, muted: false)
        XCTAssertEqual(sut.overlay, .unmuted)
        XCTAssertEqual(sut.knownState, .unmuted)
    }

    func testButtonNotFound() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .buttonNotFound, muted: nil)
        XCTAssertEqual(sut.overlay, .buttonNotFound)
        XCTAssertEqual(sut.knownState, .unknown)
    }

    func testDisconnectWipesState() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .inCall, muted: false)
        sut.bridgeDisconnected()
        XCTAssertEqual(sut.overlay, .noBridge)
        XCTAssertEqual(sut.knownState, .unknown)
    }

    func testInCallWithoutMutedFlagIsTreatedAsButtonNotFound() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .inCall, muted: nil)
        XCTAssertEqual(sut.overlay, .buttonNotFound,
                       "состояние без data-muted бесполезно — честнее показать проблему")
    }

    // MARK: подтверждение команд

    func testPendingIsSetOnCommandAndClearedByConfirmation() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .inCall, muted: true)

        sut.commandSent(at: 100)
        XCTAssertTrue(sut.isPending)

        sut.apply(context: .inCall, muted: false)
        XCTAssertFalse(sut.isPending)
        XCTAssertEqual(sut.overlay, .unmuted)
    }

    func testPendingExpiresAfterTimeoutAndStateStaysConfirmed() {
        let sut = MicStateStore()
        sut.bridgeConnected()
        sut.apply(context: .inCall, muted: true)
        sut.commandSent(at: 100)

        sut.tick(now: 100 + MicStateStore.confirmationTimeout - 0.05)
        XCTAssertTrue(sut.isPending)

        // Границу проверяем с запасом: 100 + 0.8 - 100 в double не даёт ровно 0.8,
        // а точность границы здесь не требование — таймаут пользователю не виден.
        sut.tick(now: 100 + MicStateStore.confirmationTimeout + 0.05)
        XCTAssertFalse(sut.isPending)
        XCTAssertEqual(sut.overlay, .muted,
                       "плашка показывает последнее подтверждённое состояние, а не желаемое")
    }

    // MARK: уведомления

    func testOnChangeFiresOnlyWhenSomethingActuallyChanges() {
        let sut = MicStateStore()
        sut.bridgeConnected()

        var calls: [(OverlayState, Bool)] = []
        sut.onChange = { calls.append(($0, $1)) }

        sut.apply(context: .inCall, muted: true)
        sut.apply(context: .inCall, muted: true)   // дубликат — уведомления быть не должно

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, .muted)
    }

    func testOnChangeFiresForEveryRealTransition() {
        let sut = MicStateStore()
        var states: [OverlayState] = []
        sut.onChange = { state, _ in states.append(state) }

        sut.bridgeConnected()
        sut.apply(context: .inCall, muted: true)

        XCTAssertEqual(states, [.noCall, .muted])
    }
}

import XCTest
@testable import SordioCore

final class PressInterpreterTests: XCTestCase {

    private func makeInterpreter() -> PressInterpreter {
        PressInterpreter(holdThreshold: 0.35)
    }

    // MARK: короткое нажатие = переключение

    func testShortPressFromMutedUnmutesOnKeyDownAndKeepsIt() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.keyDown(at: 0, micState: .muted), .setMuted(false),
                       "микрофон должен открыться на нажатии, чтобы не съесть начало фразы")
        XCTAssertEqual(sut.keyUp(at: 0.1), .none,
                       "переключение уже произошло — на отпускании ничего делать не нужно")
    }

    func testShortPressFromUnmutedMutesOnKeyUp() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.keyDown(at: 0, micState: .unmuted), .none)
        XCTAssertEqual(sut.keyUp(at: 0.1), .setMuted(true))
    }

    // MARK: удержание = push-to-talk

    func testHoldFromMutedRestoresMuteOnRelease() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.keyDown(at: 0, micState: .muted), .setMuted(false))
        XCTAssertEqual(sut.keyUp(at: 2.0), .setMuted(true))
    }

    func testHoldFromUnmutedDoesNothing() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.keyDown(at: 0, micState: .unmuted), .none)
        XCTAssertEqual(sut.keyUp(at: 2.0), .none,
                       "клавиша не должна отключать человека посреди фразы")
    }

    // MARK: граница порога

    func testExactlyAtThresholdCountsAsHold() {
        var sut = makeInterpreter()
        _ = sut.keyDown(at: 0, micState: .unmuted)
        XCTAssertEqual(sut.keyUp(at: 0.35), .none)
    }

    func testJustBelowThresholdCountsAsShortPress() {
        var sut = makeInterpreter()
        _ = sut.keyDown(at: 0, micState: .unmuted)
        XCTAssertEqual(sut.keyUp(at: 0.349), .setMuted(true))
    }

    // MARK: автоповтор

    func testAutorepeatKeyDownsAreIgnored() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.keyDown(at: 0, micState: .muted), .setMuted(false))
        XCTAssertEqual(sut.keyDown(at: 0.1, micState: .unmuted), .none)
        XCTAssertEqual(sut.keyDown(at: 0.2, micState: .unmuted), .none)
        XCTAssertEqual(sut.keyUp(at: 2.0), .setMuted(true),
                       "исходное состояние должно остаться тем, что было при первом нажатии")
    }

    // MARK: неизвестное состояние

    func testKeyDownWithUnknownStateFlashesAndSendsNothing() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.keyDown(at: 0, micState: .unknown), .flashUnavailable)
        XCTAssertEqual(sut.keyUp(at: 0.1), .none)
    }

    // MARK: мусорные события

    func testKeyUpWithoutKeyDownIsIgnored() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.keyUp(at: 1.0), .none)
    }

    func testSecondKeyUpIsIgnored() {
        var sut = makeInterpreter()
        _ = sut.keyDown(at: 0, micState: .unmuted)
        XCTAssertEqual(sut.keyUp(at: 0.1), .setMuted(true))
        XCTAssertEqual(sut.keyUp(at: 0.2), .none)
    }

    // MARK: аварийное завершение

    func testCancelDuringHoldFromMutedRestoresMute() {
        var sut = makeInterpreter()
        _ = sut.keyDown(at: 0, micState: .muted)
        XCTAssertEqual(sut.cancel(), .setMuted(true))
    }

    func testCancelWithoutActivePressIsIgnored() {
        var sut = makeInterpreter()
        XCTAssertEqual(sut.cancel(), .none)
    }

    func testKeyUpAfterCancelIsIgnored() {
        var sut = makeInterpreter()
        _ = sut.keyDown(at: 0, micState: .muted)
        _ = sut.cancel()
        XCTAssertEqual(sut.keyUp(at: 1.0), .none)
    }

    // MARK: - исход, отложенный до восстановления связи

    func testInterruptedHoldIsRestoredAfterReconnect() {
        // Человек держит хоткей (микрофон открыт), связь рвётся. Отправить
        // «верни как было» некому — исход надо придержать и отдать сразу
        // после восстановления связи, иначе микрофон останется открытым
        // навсегда: настоящее отпускание уже ничего не сделает.
        var sut = makeInterpreter()
        var deferred = DeferredOutcome()

        _ = sut.keyDown(at: 0, micState: .muted)
        deferred.store(sut.cancel())

        XCTAssertFalse(deferred.isEmpty, "исход cancel() нельзя выбрасывать")
        XCTAssertEqual(deferred.take(), .setMuted(true))
    }

    func testDeferredOutcomeIsDeliveredOnlyOnce() {
        var deferred = DeferredOutcome()
        deferred.store(.setMuted(true))

        XCTAssertEqual(deferred.take(), .setMuted(true))
        XCTAssertEqual(deferred.take(), .none,
                       "повторное подключение не должно заново глушить микрофон")
    }

    func testNothingIsDeferredWhenHoldWasNotFromMuted() {
        // Удержание из «микрофон уже открыт» ничего не меняло — восстанавливать
        // после переподключения нечего.
        var sut = makeInterpreter()
        var deferred = DeferredOutcome()

        _ = sut.keyDown(at: 0, micState: .unmuted)
        deferred.store(sut.cancel())

        XCTAssertTrue(deferred.isEmpty)
        XCTAssertEqual(deferred.take(), .none)
    }

    func testDisconnectWithoutActivePressDefersNothing() {
        var sut = makeInterpreter()
        var deferred = DeferredOutcome()

        deferred.store(sut.cancel())

        XCTAssertTrue(deferred.isEmpty, "обрыв связи без удержания ничего не откладывает")
    }
}

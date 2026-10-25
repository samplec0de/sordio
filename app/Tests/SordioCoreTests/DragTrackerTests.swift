import XCTest
@testable import SordioCore

final class DragTrackerTests: XCTestCase {

    private func tracker(mouse: CGPoint = CGPoint(x: 100, y: 100),
                         origin: CGPoint = CGPoint(x: 800, y: 700)) -> DragTracker {
        var tracker = DragTracker()
        tracker.begin(mouse: mouse, windowOrigin: origin)
        return tracker
    }

    func testPressAndReleaseIsAClick() {
        var t = tracker()
        XCTAssertTrue(t.end())
    }

    /// Рука дрожит: пара пикселей — ещё клик, окно не двигается.
    func testSmallJitterStaysAClickAndDoesNotMoveWindow() {
        var t = tracker()
        XCTAssertNil(t.move(to: CGPoint(x: 102, y: 101)))
        XCTAssertTrue(t.end())
    }

    func testDragMovesWindowByTheMouseDelta() {
        var t = tracker()
        XCTAssertEqual(t.move(to: CGPoint(x: 140, y: 90)), CGPoint(x: 840, y: 690))
        XCTAssertEqual(t.move(to: CGPoint(x: 160, y: 130)), CGPoint(x: 860, y: 730))
        XCTAssertFalse(t.end())
    }

    /// Первые пиксели до порога не теряются: окно прыгает сразу в итоговую
    /// точку, а не отстаёт от курсора на величину порога.
    func testWindowFollowsTheFullDeltaOnceThresholdIsCrossed() {
        var t = tracker()
        XCTAssertNil(t.move(to: CGPoint(x: 102, y: 100)))
        XCTAssertEqual(t.move(to: CGPoint(x: 110, y: 100)), CGPoint(x: 810, y: 700))
    }

    /// Увёл плашку и вернул курсор на место — это всё равно перетаскивание,
    /// иначе отпускание превратилось бы в случайное переключение микрофона.
    func testReturningToStartDoesNotTurnADragIntoAClick() {
        var t = tracker()
        XCTAssertNotNil(t.move(to: CGPoint(x: 150, y: 100)))
        XCTAssertEqual(t.move(to: CGPoint(x: 100, y: 100)), CGPoint(x: 800, y: 700))
        XCTAssertFalse(t.end())
    }

    func testReleaseWithoutPressIsNotAClick() {
        var t = DragTracker()
        XCTAssertFalse(t.end())
    }

    func testMoveWithoutPressDoesNothing() {
        var t = DragTracker()
        XCTAssertNil(t.move(to: CGPoint(x: 500, y: 500)))
    }

    /// Следующий жест начинается с чистого листа.
    func testNextGestureStartsFresh() {
        var t = tracker()
        XCTAssertNotNil(t.move(to: CGPoint(x: 200, y: 200)))
        XCTAssertFalse(t.end())
        t.begin(mouse: CGPoint(x: 5, y: 5), windowOrigin: CGPoint(x: 1, y: 1))
        XCTAssertTrue(t.end())
    }
}

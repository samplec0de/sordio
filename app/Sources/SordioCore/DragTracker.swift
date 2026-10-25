import CoreGraphics

/// Отличает перетаскивание плашки от клика по ней.
///
/// Мышь на плашке делает два дела: клик переключает микрофон, перетаскивание
/// двигает окно. Различает их порог: пока курсор не ушёл дальше нескольких
/// пикселей, это ещё клик — рука всегда чуть дрожит. Координаты — экранные.
public struct DragTracker {
    public static let threshold: CGFloat = 3

    private var startMouse: CGPoint?
    private var startOrigin: CGPoint = .zero
    private var exceededThreshold = false

    public init() {}

    public mutating func begin(mouse: CGPoint, windowOrigin: CGPoint) {
        startMouse = mouse
        startOrigin = windowOrigin
        exceededThreshold = false
    }

    /// Новое положение окна, если жест уже стал перетаскиванием, иначе `nil`.
    /// Став перетаскиванием, жест им и остаётся — возврат курсора к началу
    /// не превращает его обратно в клик.
    public mutating func move(to mouse: CGPoint) -> CGPoint? {
        guard let startMouse else { return nil }
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        if !exceededThreshold {
            guard (dx * dx + dy * dy).squareRoot() > Self.threshold else { return nil }
            exceededThreshold = true
        }
        return CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
    }

    /// Жест окончен. `true` — это был клик, а не перетаскивание.
    public mutating func end() -> Bool {
        defer {
            startMouse = nil
            exceededThreshold = false
        }
        return startMouse != nil && !exceededThreshold
    }
}

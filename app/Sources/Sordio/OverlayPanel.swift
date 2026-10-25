import AppKit
import SordioCore
import SwiftUI

/// SwiftUI-содержимое перехватывает мышь, и `isMovableByWindowBackground`
/// на нём не срабатывает: плашку нельзя было сдвинуть. Поэтому перетаскивание
/// сделано явно, а клик без движения — это нажатие на плашку.
private final class OverlayHostingView: NSHostingView<OverlayView> {
    var onClick: (() -> Void)?
    private var drag = DragTracker()

    override var mouseDownCanMoveWindow: Bool { false }

    /// Плашка не активирует приложение, и первый клик по ней не должен
    /// тратиться на «захват» окна.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        drag.begin(mouse: NSEvent.mouseLocation, windowOrigin: window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let origin = drag.move(to: NSEvent.mouseLocation) else { return }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        if drag.end() { onClick?() }
    }
}

/// Плашка поверх всех окон, включая полноэкранные приложения и все Spaces.
final class OverlayPanel {
    private let panel: NSPanel
    private let model: OverlayModel
    /// Отложенный сброс подсветки — отменяется при повторном `flash()`,
    /// чтобы быстрые повторные нажатия продлевали подсветку, а не гасили её раньше времени.
    private var flashResetWork: DispatchWorkItem?

    init(model: OverlayModel, onToggle: @escaping () -> Void) {
        self.model = model

        let hosting = OverlayHostingView(rootView: OverlayView(model: model))
        hosting.onClick = onToggle
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 34)

        panel = NSPanel(contentRect: hosting.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Уровень выше обычных окон, чтобы плашка не пряталась за полноэкранными приложениями.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        restorePosition()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Preferences.shared.overlayOrigin = self.panel.frame.origin
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Короткая подсветка — чтобы нажатие в нерабочем состоянии не пропало молча.
    ///
    /// Повторный вызов отменяет ранее запланированный сброс и планирует новый,
    /// поэтому серия быстрых нажатий продлевает подсветку от момента последнего
    /// из них, а не гаснет по таймеру самого первого.
    func flash() {
        flashResetWork?.cancel()
        model.flash = true

        let work = DispatchWorkItem { [weak self] in
            self?.model.flash = false
        }
        flashResetWork = work
        // 0.5 с — заметно дольше, чем нужно для чтения одной сплошной заливки,
        // но не настолько долго, чтобы плашка ощущалась зависшей.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restorePosition() {
        if let origin = Preferences.shared.overlayOrigin,
           NSScreen.screens.contains(where: { $0.frame.contains(origin) }) {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.minY + 80))
        }
    }
}

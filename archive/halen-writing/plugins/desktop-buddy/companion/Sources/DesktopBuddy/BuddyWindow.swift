import Cocoa
import SwiftUI

/// Floating borderless circular window that draws the buddy character.
/// Always-on-top, draggable by holding-and-moving (a quick click opens the
/// input bubble instead), positioned bottom-right of the visible screen on
/// first launch.
final class BuddyWindow: NSPanel {

    static let size: CGFloat = 96

    private let model: BuddyModel
    private let onClick: () -> Void

    init(model: BuddyModel, onClick: @escaping () -> Void) {
        self.model = model
        self.onClick = onClick

        let rect = NSRect(x: 0, y: 0, width: BuddyWindow.size, height: BuddyWindow.size)
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false

        let host = NSHostingView(rootView: BuddyView(model: model))
        host.frame = rect
        host.autoresizingMask = [.width, .height]

        let dispatcher = ClickDragDispatcher(content: host, onClick: onClick)
        self.contentView = dispatcher

        positionInDefaultLocation()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom-right of the screen with margin so the buddy doesn't crowd
    /// the dock.
    private func positionInDefaultLocation() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 32
        let origin = NSPoint(
            x: visible.maxX - BuddyWindow.size - margin,
            y: visible.minY + margin + 80
        )
        self.setFrameOrigin(origin)
    }
}

/// Carries the SwiftUI content but owns mouse handling so we can
/// distinguish a click (open input bubble) from a drag (move the window).
/// We deliberately do NOT use `isMovableByWindowBackground` because it only
/// fires when no subview handles the event, and we always need to handle
/// the down to detect taps.
private final class ClickDragDispatcher: NSView {
    private let onClick: () -> Void
    private let content: NSView
    private var mouseDownScreenLocation: NSPoint = .zero
    private var windowOriginAtMouseDown: NSPoint = .zero
    private var dragged = false

    init(content: NSView, onClick: @escaping () -> Void) {
        self.content = content
        self.onClick = onClick
        super.init(frame: content.frame)
        self.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let here = NSEvent.mouseLocation
        let dx = here.x - mouseDownScreenLocation.x
        let dy = here.y - mouseDownScreenLocation.y
        if !dragged && (abs(dx) > 3 || abs(dy) > 3) {
            dragged = true
        }
        if dragged {
            win.setFrameOrigin(NSPoint(
                x: windowOriginAtMouseDown.x + dx,
                y: windowOriginAtMouseDown.y + dy
            ))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick() }
    }
}

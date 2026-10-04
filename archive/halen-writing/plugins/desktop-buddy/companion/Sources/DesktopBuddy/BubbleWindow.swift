import Cocoa
import SwiftUI

/// Floating bubble window anchored to the buddy. Can be in one of three
/// modes: idle (hidden), `.say` (showing a string), `.input` (a text field
/// for the user to type into). Hosted by `AppDelegate` and toggled in
/// response to bridge messages.
final class BubbleWindow: NSPanel {

    static let width: CGFloat = 320
    static let maxHeight: CGFloat = 240

    private let model: BubbleModel
    private let onSubmit: (String) -> Void
    private let onClose: () -> Void

    init(model: BubbleModel,
         onSubmit: @escaping (String) -> Void,
         onClose: @escaping () -> Void) {
        self.model = model
        self.onSubmit = onSubmit
        self.onClose = onClose

        let rect = NSRect(x: 0, y: 0, width: BubbleWindow.width, height: 140)
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered,
                   defer: false)

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true

        let root = BubbleView(
            model: model,
            onSubmit: { [weak self] text in self?.onSubmit(text) },
            onClose:  { [weak self] in self?.onClose() }
        )
        let host = NSHostingView(rootView: root)
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        self.contentView = host
    }

    /// We want the text field to receive keystrokes when the input bubble is
    /// shown, without yanking focus away from the user's frontmost app
    /// permanently — `becomesKeyOnlyIfNeeded` + `.nonactivatingPanel`
    /// handles the latter; this enables the former.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Position the bubble above + slightly left of the buddy, clamped to
    /// the visible screen.
    func anchor(to buddy: NSWindow) {
        guard let screen = buddy.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let bf = buddy.frame
        let size = self.frame.size
        let gap: CGFloat = 14
        var origin = NSPoint(
            x: bf.minX - size.width + 60,
            y: bf.maxY + gap
        )
        // If we'd run off the top, drop the bubble below the buddy instead.
        if origin.y + size.height > visible.maxY {
            origin.y = bf.minY - size.height - gap
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, origin.y)
        self.setFrameOrigin(origin)
    }
}

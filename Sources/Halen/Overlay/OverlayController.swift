import AppKit
import SwiftUI

/// Reactive state for the caret indicator view. `OverlayController` retains one
/// instance and flips `isBusy`; the SwiftUI view observes it and swaps between
/// the static mark and the animated "working" mark — no `rootView` reassignment,
/// so in-flight animations aren't torn down.
@MainActor
@Observable
final class OverlayIndicatorModel {
    var isBusy = false
}

/// Shows a small Halen-logo indicator next to the caret of the focused text
/// field. Follows `caret.moved` events; hides itself after a couple of seconds
/// of caret inactivity. User can turn it off via Settings → Cursor overlay.
///
/// While a Gemma-backed plugin is mid-call it also shows a "busy" state — the
/// mark animates and stays put — driven by `inference.activity` events on the
/// bus, so the user knows something is happening during the multi-second wait.
@MainActor
final class OverlayController {
    private let eventBus: EventBus
    private var window: NSPanel?
    private var subscribeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    private let model = OverlayIndicatorModel()

    /// Number of in-flight inference calls. The indicator stays busy until this
    /// returns to 0, so overlapping expansions don't revert it prematurely.
    private var busyDepth = 0
    /// Most recent caret rect seen on the bus — used to anchor the busy
    /// indicator even if no fresh `caret.moved` arrives.
    private var lastCaretRect: Event.CaretRect?

    private static let dotSize: CGFloat = 16

    /// UserDefaults key. Read on every `show()` so the toggle takes effect live.
    static let showDotKey = "halen.showOverlayDot"

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func start() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: HalenCaretIndicator(model: model))

        window = panel

        subscribeTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let payload):
                    self.lastCaretRect = payload.rect
                    // While busy, hold position — the placeholder write and the
                    // final response write both fire `caret.moved`, and chasing
                    // them makes the indicator jump around.
                    if self.busyDepth == 0 {
                        self.show(at: payload.rect)
                    }
                case .inferenceActivity(let payload):
                    switch payload.phase {
                    case .started:
                        self.busyDepth += 1
                        if self.busyDepth == 1 { self.enterBusy() }
                    case .finished:
                        self.busyDepth = max(0, self.busyDepth - 1)
                        if self.busyDepth == 0 { self.exitBusy() }
                    }
                default:
                    break
                }
            }
        }

        // Hide instantly if the user disables the indicator in Settings.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !Self.indicatorEnabled {
                    self.window?.orderOut(nil)
                }
            }
        }
    }

    func stop() {
        subscribeTask?.cancel()
        hideTask?.cancel()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        busyDepth = 0
        model.isBusy = false
        window?.orderOut(nil)
        window = nil
    }

    static var indicatorEnabled: Bool {
        UserDefaults.standard.object(forKey: showDotKey) as? Bool ?? true
    }

    /// Indicator frame: just to the right of the caret, vertically centered on it.
    private func frame(for caret: Event.CaretRect, size: CGFloat) -> NSRect {
        NSRect(
            x: caret.x + 6,
            y: caret.y + (caret.height - size) / 2,
            width: size,
            height: size
        )
    }

    private func show(at caret: Event.CaretRect) {
        guard Self.indicatorEnabled, let window else { return }
        window.setFrame(frame(for: caret, size: Self.dotSize), display: true)
        window.orderFrontRegardless()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.window?.orderOut(nil)
        }
    }

    /// Enter the "working" state: keep the indicator visible and animating,
    /// anchored at the last known caret position, with no auto-hide.
    private func enterBusy() {
        guard Self.indicatorEnabled, let window else { return }
        guard let caret = lastCaretRect else {
            Log.debug("OverlayController: enterBusy with no known caret rect — skipping visual")
            return
        }
        hideTask?.cancel()
        window.setFrame(frame(for: caret, size: Self.dotSize), display: true)
        model.isBusy = true
        window.orderFrontRegardless()
    }

    /// Leave the "working" state: revert to the static mark and resume the
    /// normal 2-second auto-hide. Position is left as-is.
    private func exitBusy() {
        model.isBusy = false
        scheduleAutoHide()
    }
}

/// The caret indicator view. Observes `OverlayIndicatorModel` and swaps between
/// the static Halen mark and the animated "working" mark.
private struct HalenCaretIndicator: View {
    let model: OverlayIndicatorModel

    var body: some View {
        Group {
            if model.isBusy {
                BusyMark()
            } else {
                StaticMark()
            }
        }
    }
}

/// Small solid cobalt-blue Halen mark used as the caret indicator. Source is
/// `HalenIndicator.png` (rendered from `Resources/HalenSolid.svg`), already
/// the right colour — no SwiftUI tinting needed. Falls back to a coloured
/// circle if the asset isn't bundled.
private struct StaticMark: View {
    private static let cobalt = Color(red: 0.0, green: 0.30, blue: 0.99)

    var body: some View {
        Group {
            if let img = NSImage(named: "HalenIndicator") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Circle()
                    .fill(Self.cobalt)
                    .padding(2)
            }
        }
        .shadow(color: Self.cobalt.opacity(0.35), radius: 2, x: 0, y: 1)
    }
}

/// "Working" caret indicator: the Halen mark breathes (scale + opacity) inside
/// a faint, slowly rotating cobalt arc. Fits the same 16×16 footprint as the
/// static mark, so the overlay panel never needs resizing.
private struct BusyMark: View {
    private static let cobalt = Color(red: 0.0, green: 0.30, blue: 0.99)
    @State private var animating = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.7)
                .stroke(
                    Self.cobalt.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(animating ? 360 : 0))
                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: animating)

            mark
                .scaleEffect(animating ? 1.0 : 0.7)
                .opacity(animating ? 1.0 : 0.55)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: animating)
        }
        .padding(1)
        .onAppear { animating = true }
    }

    @ViewBuilder
    private var mark: some View {
        if let img = NSImage(named: "HalenIndicator") {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .padding(2.5)
        } else {
            Circle()
                .fill(Self.cobalt)
                .padding(3)
        }
    }
}

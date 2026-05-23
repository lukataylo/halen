import AppKit
import SwiftUI

/// Two independent floating panels next to the focused text field:
///
///  - `caretPanel` — the always-on 16×16 Halen-logo caret indicator. Follows
///    `caret.moved`, auto-hides after a couple of seconds of inactivity. This
///    is deliberately the simplest possible structure (the SwiftUI logo *is*
///    the panel's content view) — it is the proven original and the busy-state
///    code must never touch it.
///  - `busyPanel` — a 40×40 "AI working" loader shown only while a Gemma call
///    is in flight (driven by `inference.activity`). A separate panel so its
///    extra structure (a container with a centered logo + a rotating ring)
///    can't regress the caret indicator.
///
/// User can turn the whole thing off via Settings → Cursor overlay.
@MainActor
final class OverlayController {
    private let eventBus: EventBus
    /// Shared observable state for the caret indicator (severity tint,
    /// hover state). Owned here; observed by `HalenCaretIndicator` so the
    /// SwiftUI view re-renders on every change without recreating the
    /// `NSHostingView`.
    let indicatorState = OverlayIndicatorState()

    private var caretPanel: NSPanel?
    private var busyPanel: NSPanel?
    private var busyContainer: NSView?
    private var busyLogo: NSHostingView<HalenCaretIndicator>?
    private var ringLayer: CAShapeLayer?

    /// Active findings keyed by source plugin id. One finding per source so
    /// re-classifying the same paragraph (or the next one) cleanly replaces
    /// the prior signal instead of stacking. The combined severity drives the
    /// indicator's tint.
    private var activeFindings: [String: Event.FindingDetected] = [:]

    private var subscribeTask: Task<Void, Never>?
    /// Single auto-hide task. Each `caret.moved` pushes `hideDeadline` out;
    /// the running task picks it up on its next wake instead of being cancelled
    /// and respawned per event.
    private var hideTask: Task<Void, Never>?
    private var hideDeadline: Date?
    /// Last frame we set on `caretPanel`. Used to skip redundant `setFrame`
    /// calls when AX value-changed notifications fire without the cursor
    /// actually moving (very common during typing).
    private var lastCaretFrame: NSRect?
    private var defaultsObserver: NSObjectProtocol?

    /// In-flight inference calls. The loader stays up until this returns to 0.
    private var busyDepth = 0
    /// Force-resets `busyDepth` if no `.finished` arrives in time. The
    /// EventBus has a bounded buffer that drops oldest on overflow — if a
    /// `.finished` were ever dropped, `busyDepth` would stay positive and the
    /// loader panel would hang up forever. This is the recovery valve.
    private var busyWatchdog: Task<Void, Never>?
    /// Longer than any realistic inference (debounced classification +
    /// generation top out well under this); only a genuinely stuck/lost
    /// `.finished` reaches it.
    private static let busyWatchdogTimeout: Duration = .seconds(25)
    /// Most recent caret rect — fallback anchor for the loader.
    private var lastCaretRect: Event.CaretRect?
    /// Explicit anchor from the active inference source (e.g. a placeholder's
    /// on-screen bounds). Preferred over `lastCaretRect` while busy.
    private var busyAnchor: Event.CaretRect?

    fileprivate static let dotSize: CGFloat = 16
    /// Larger frame when a finding is active — gives a generous hover/click
    /// target without the SwiftUI view needing to reposition. The panel is
    /// always sized to this; the indicator art scales between `dotSize` and
    /// `findingDotSize` based on `indicatorState.severity`.
    fileprivate static let findingDotSize: CGFloat = 24
    private static let busySize: CGFloat = 40
    private static let glowKey = "halen.busy.glow"

    /// UserDefaults key. Read on every `showCaret()` so the toggle takes effect live.
    static let showDotKey = "halen.showOverlayDot"

    /// UserDefaults key for the indicator's visual style. Two values:
    /// `"solid"` (default — filled cobalt mark) and `"outline"` (white-filled
    /// speech bubble with a cobalt outline and eyes). `HalenCaretIndicator`
    /// reads this via `@AppStorage` so the toggle takes effect live.
    static let dotStyleKey = "halen.overlayDotStyle"

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func start() {
        // Caret indicator: the SwiftUI logo is the content view directly — no
        // container, no offset subview. This is the proven original layout.
        // The indicator panel sizes to the larger `findingDotSize`; the
        // SwiftUI view inside renders at `dotSize` when there are no findings
        // (looks identical to the original) and expands to fill when one
        // appears. The bigger frame gives the hover target a fighting chance
        // without the panel having to reframe on every state change.
        let caret = Self.makePanel(size: Self.findingDotSize)
        caret.contentView = NSHostingView(
            rootView: HalenCaretIndicator(state: indicatorState))
        caretPanel = caret

        // Busy loader: a fixed 40×40 container with the 16×16 logo pinned dead
        // centre via Auto Layout (so NSHostingView sizing quirks can't shift
        // it) and room in the margin for the rotating ring sublayer.
        let busy = Self.makePanel(size: Self.busySize)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.busySize, height: Self.busySize))
        container.wantsLayer = true
        let logo = NSHostingView(rootView: HalenCaretIndicator(state: OverlayIndicatorState()))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.sizingOptions = []
        logo.wantsLayer = true
        container.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: Self.dotSize),
            logo.heightAnchor.constraint(equalToConstant: Self.dotSize),
        ])
        busy.contentView = container
        busyPanel = busy
        busyContainer = container
        busyLogo = logo

        subscribeTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let payload):
                    self.lastCaretRect = payload.rect
                    // While busy, hold position — let the loader sit where it is.
                    if self.busyDepth == 0 {
                        self.showCaret(at: payload.rect)
                    }
                case .inferenceActivity(let payload):
                    switch payload.phase {
                    case .started:
                        if let anchor = payload.anchor { self.busyAnchor = anchor }
                        self.busyDepth += 1
                        if self.busyDepth == 1 { self.enterBusy() }
                        self.armBusyWatchdog()
                    case .finished:
                        self.busyDepth = max(0, self.busyDepth - 1)
                        if self.busyDepth == 0 { self.exitBusy() }
                        else { self.armBusyWatchdog() }   // still busy — re-arm
                    }
                case .findingDetected(let payload):
                    self.upsertFinding(payload)
                case .findingsCleared(let payload):
                    self.clearFindings(source: payload.source, id: payload.id)
                case .appFocused:
                    // Findings are paragraph-scoped; switching apps means the
                    // user is doing something else and stale tints would lie.
                    if !self.activeFindings.isEmpty {
                        self.activeFindings.removeAll()
                        self.recomputeIndicatorState()
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
                    self.caretPanel?.orderOut(nil)
                    self.busyPanel?.orderOut(nil)
                }
            }
        }
    }

    func stop() {
        subscribeTask?.cancel()
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
        lastCaretFrame = nil
        busyWatchdog?.cancel()
        busyWatchdog = nil
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        busyDepth = 0
        removeGlow()
        caretPanel?.orderOut(nil)
        busyPanel?.orderOut(nil)
        caretPanel = nil
        busyPanel = nil
    }

    static var indicatorEnabled: Bool {
        UserDefaults.standard.object(forKey: showDotKey) as? Bool ?? true
    }

    private static func makePanel(size: CGFloat) -> NSPanel {
        // Caret indicator: always-on chrome, pure decoration (no shadow under
        // a 16 pt mark), clicks pass straight through to the app underneath.
        HalenFloatingPanel.make(
            size: NSSize(width: size, height: size),
            level: .statusBar,
            interactive: false,
            shadow: false
        )
    }

    // MARK: - Caret indicator (the proven original)

    private func showCaret(at caret: Event.CaretRect) {
        guard Self.indicatorEnabled, let panel = caretPanel else { return }
        // Just right of the caret, vertically centered on it.
        let frame = NSRect(
            x: CGFloat(caret.x) + 6,
            y: CGFloat(caret.y) + (CGFloat(caret.height) - Self.dotSize) / 2,
            width: Self.dotSize,
            height: Self.dotSize
        )
        // Skip the reframe + sync redraw if the cursor hasn't actually moved.
        // `display: false` lets AppKit coalesce the next paint with the natural
        // run-loop tick instead of forcing a synchronous draw on every keystroke.
        if frame != lastCaretFrame {
            panel.setFrame(frame, display: false)
            lastCaretFrame = frame
        }
        panel.orderFrontRegardless()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        // Push the deadline out. If a hide task is already running, it will
        // observe the new deadline on its next wake and re-sleep — no need to
        // cancel and respawn a fresh `Task` per `caret.moved` event.
        let deadline = Date().addingTimeInterval(2)
        hideDeadline = deadline
        if hideTask != nil { return }
        hideTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let target = self.hideDeadline else { return }
                let remaining = target.timeIntervalSinceNow
                if remaining <= 0 {
                    self.caretPanel?.orderOut(nil)
                    self.lastCaretFrame = nil   // next show must re-set the frame
                    self.hideTask = nil
                    self.hideDeadline = nil
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    // MARK: - Busy loader (separate panel)

    /// Enter the "AI working" state: hand off from the caret indicator to the
    /// loader panel, anchored at the inference source's location.
    private func enterBusy() {
        guard Self.indicatorEnabled, let busyPanel else { return }
        // Cancel + clear so the next `scheduleAutoHide` after exitBusy spawns
        // a fresh task instead of seeing the stale (cancelled) reference.
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
        caretPanel?.orderOut(nil)
        lastCaretFrame = nil

        if let anchor = busyAnchor ?? lastCaretRect {
            // Position so the centered 16×16 logo lands where the caret
            // indicator would have — just right of the anchor.
            let inset = (Self.busySize - Self.dotSize) / 2
            let frame = NSRect(
                x: CGFloat(anchor.x) + 6 - inset,
                y: CGFloat(anchor.y) + (CGFloat(anchor.height) - Self.dotSize) / 2 - inset,
                width: Self.busySize,
                height: Self.busySize
            )
            busyPanel.setFrame(frame, display: true)
        }
        busyPanel.orderFrontRegardless()
        addGlow()
    }

    /// Leave the busy state: hide the loader and hand back to the caret indicator.
    private func exitBusy() {
        busyWatchdog?.cancel()
        busyWatchdog = nil
        removeGlow()
        busyAnchor = nil
        busyPanel?.orderOut(nil)
        if let caret = lastCaretRect {
            showCaret(at: caret)
        }
    }

    /// (Re)arm the watchdog that recovers a stuck busy state — see
    /// `busyWatchdog`. Called on every `.started` and on every `.finished`
    /// that leaves `busyDepth` still positive, so the timeout is measured
    /// from the most recent activity, not the first.
    private func armBusyWatchdog() {
        busyWatchdog?.cancel()
        busyWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.busyWatchdogTimeout)
            guard let self, !Task.isCancelled, self.busyDepth > 0 else { return }
            Log.warn("OverlayController: busy watchdog fired — \(self.busyDepth) inference(s) never reported finished; force-clearing the loader")
            self.busyDepth = 0
            self.exitBusy()
        }
    }

    private func addGlow() {
        guard let container = busyContainer, let layer = container.layer else { return }

        // Rotating cobalt arc in the margin around the logo.
        let ring = CAShapeLayer()
        ring.frame = container.bounds
        let diameter = Self.dotSize + 12
        let ringRect = CGRect(
            x: (Self.busySize - diameter) / 2,
            y: (Self.busySize - diameter) / 2,
            width: diameter,
            height: diameter
        )
        ring.path = CGPath(ellipseIn: ringRect, transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = CGColor.halenCobalt.copy(alpha: 0.55)
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeStart = 0.0
        ring.strokeEnd = 0.7
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.0
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
        layer.addSublayer(ring)
        ringLayer = ring

        // Breathing glow on the logo itself — opacity only, so its size is untouched.
        if let logoLayer = busyLogo?.layer {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1.0
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            logoLayer.add(pulse, forKey: Self.glowKey)
        }
    }

    private func removeGlow() {
        ringLayer?.removeFromSuperlayer()
        ringLayer = nil
        busyLogo?.layer?.removeAnimation(forKey: Self.glowKey)
    }

    // MARK: - Findings

    /// Apply (or replace) the active finding for `payload.source`. One
    /// finding per source — re-classification of the same paragraph or a
    /// fresh paragraph from the same plugin cleanly replaces the prior.
    private func upsertFinding(_ payload: Event.FindingDetected) {
        activeFindings[payload.source] = payload
        recomputeIndicatorState()
    }

    /// Drop matching finding(s). `id == nil` clears every finding from
    /// `source`; otherwise only the one whose id matches.
    private func clearFindings(source: String, id: String?) {
        if let id {
            if activeFindings[source]?.id == id {
                activeFindings.removeValue(forKey: source)
            }
        } else {
            activeFindings.removeValue(forKey: source)
        }
        recomputeIndicatorState()
    }

    /// Rebuild the SwiftUI-visible indicator state from `activeFindings`. The
    /// strongest-severity finding wins the tint; the summaries are joined for
    /// the hover popover. Also flips the caret panel between click-through
    /// (no findings) and interactive (findings — needed for hover events to
    /// reach the SwiftUI view).
    private func recomputeIndicatorState() {
        let highest = activeFindings.values.max(by: { $0.severity < $1.severity })
        indicatorState.findings = activeFindings.values
            .sorted { $0.severity > $1.severity }
        indicatorState.severity = highest?.severity

        // Toggle pass-through. While idle the panel must let clicks through
        // (the user is still typing into the underlying field); during a
        // finding it has to capture hover/clicks so the popover can engage.
        // `.statusBar` level keeps it floating above target apps either way.
        caretPanel?.ignoresMouseEvents = (highest == nil)
        caretPanel?.acceptsMouseMovedEvents = (highest != nil)
    }
}

/// Observable state for the Halen caret indicator. Updated by
/// `OverlayController` whenever findings change; observed by the SwiftUI
/// `HalenCaretIndicator` so the dot re-tints without recreating the host
/// view. Hover state lives here so SwiftUI's `.onHover` can drive the
/// popover surface (still to be added in this UX iteration).
@MainActor
@Observable
final class OverlayIndicatorState {
    /// Winning severity across all active findings, `nil` when clean.
    var severity: Event.FindingDetected.Severity?
    /// Active findings, severity-sorted. The popover shows these in order.
    var findings: [Event.FindingDetected] = []
    /// SwiftUI `.onHover` toggles this. The popover uses it to know when
    /// the user is engaging with the indicator.
    var isHovering: Bool = false
}

/// The Halen mark used as the caret indicator. Two states layered into one
/// view:
///
///  - **Idle** — the original 16×16 cobalt brand mark. Two visual styles
///    switched live via the `halen.overlayDotStyle` UserDefault
///    (`"solid"` → `HalenIndicator.png`, `"outline"` → `HalenOutline.png`).
///    Falls back to a coloured circle if neither asset is bundled.
///  - **Finding present** — the dot becomes a 24×24 severity-coloured
///    circle (yellow / orange / red) with the brand mark composited in
///    white at the centre. `SentimentGuard`, `ClarityChecker`, etc. drive
///    this via `OverlayController.indicatorState.severity`.
///
/// The host panel sizes to `findingDotSize` (24) always; the SwiftUI view
/// fills with the right art for the current state so no panel reframe is
/// needed when a finding appears or clears.
struct HalenCaretIndicator: View {
    @AppStorage(OverlayController.dotStyleKey) private var dotStyle: String = "solid"
    /// Pass an empty `OverlayIndicatorState` for indicators that never need
    /// to tint (e.g. the busy-loader's centred logo).
    @Bindable var state: OverlayIndicatorState

    private var assetName: String {
        dotStyle == "outline" ? "HalenOutline" : "HalenIndicator"
    }

    var body: some View {
        ZStack {
            if let severity = state.severity {
                findingDot(for: severity)
            } else {
                idleMark
                    .frame(width: OverlayController.dotSize,
                           height: OverlayController.dotSize)
            }
        }
        .frame(width: OverlayController.findingDotSize,
               height: OverlayController.findingDotSize)
        .contentShape(Rectangle())
        .onHover { hovering in
            state.isHovering = hovering
        }
    }

    /// Brand mark — exactly the original idle indicator, kept verbatim so
    /// existing users see no visual change when nothing is flagged. No drop
    /// shadow (the panel is exactly the icon size, so any blur radius clips
    /// to a hard square; both marks are self-defining without it).
    private var idleMark: some View {
        Group {
            if let img = NSImage(named: assetName) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Circle()
                    .fill(Color.halenCobalt)
                    .padding(2)
            }
        }
    }

    /// Severity-coloured dot. The brand mark sits in white at the centre so
    /// it still reads as "Halen" rather than a generic system warning.
    private func findingDot(for severity: Event.FindingDetected.Severity) -> some View {
        let fill = Self.color(for: severity)
        return ZStack {
            Circle()
                .fill(fill)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: fill.opacity(0.45), radius: 4)
            if let img = NSImage(named: assetName) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .colorMultiply(.white)        // recolour the mark white
                    .opacity(0.95)
                    .frame(width: OverlayController.dotSize - 4,
                           height: OverlayController.dotSize - 4)
            }
        }
    }

    fileprivate static func color(for severity: Event.FindingDetected.Severity) -> Color {
        switch severity {
        case .clarity:     return Color(red: 0.93, green: 0.78, blue: 0.20)   // amber
        case .conciseness: return Color(red: 0.96, green: 0.55, blue: 0.10)   // orange
        case .tone:        return Color(red: 0.91, green: 0.30, blue: 0.24)   // red
        }
    }
}

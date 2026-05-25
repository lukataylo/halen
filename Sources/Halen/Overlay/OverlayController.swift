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
    /// The "AI working" loader is its own little controller —
    /// `BusyLoaderPanel` owns the NSPanel, the rotating ring layer, and the
    /// glow animation; this class just orchestrates when to ask it to show.
    private let busy = BusyLoaderPanel()

    /// Active findings keyed by source plugin id. One finding per source so
    /// re-classifying the same paragraph (or the next one) cleanly replaces
    /// the prior signal instead of stacking. The combined severity drives the
    /// indicator's tint.
    private var activeFindings: [String: Event.FindingDetected] = [:]
    /// Bundle id of the app the user is currently focused in. Tint only
    /// shows for findings whose `appBundleId` matches; switching to a
    /// different app hides the tint without forgetting the finding.
    private var currentAppBundleId: String?

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
    /// Pixel side of the always-on caret indicator. Read by
    /// `BusyLoaderPanel` (which centres a 16 pt logo inside its 40 pt frame)
    /// and by `HalenCaretIndicator` (the SwiftUI view) — `internal` so both
    /// sibling files can resolve it without exposing it module-publicly.
    static let dotSize: CGFloat = 16

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
        // The indicator panel stays at the original 16×16 size whether or
        // not a finding is active — only the *colour* of the mark changes.
        // Earlier prototype enlarged the frame for hover targeting; user
        // feedback was clear that a colour shift alone is the right read.
        let caret = Self.makePanel(size: Self.dotSize)
        caret.contentView = NSHostingView(
            rootView: HalenCaretIndicator(state: indicatorState))
        caretPanel = caret

        // Pop-action wiring: when a popover button is tapped, fan out a
        // `findingActionRequested` event so the originating plugin
        // (SentimentGuard / ClarityChecker / …) handles the actual work.
        indicatorState.onAction = { [eventBus] finding, action in
            eventBus.publish(.findingActionRequested(.init(
                source: finding.source,
                findingId: finding.id,
                action: action,
                timestamp: Date()
            )))
        }

        // The busy loader owns its own NSPanel + animations now — see
        // `BusyLoaderPanel`. `install()` is idempotent so re-`start()`ing
        // doesn't accumulate panels.
        busy.install()

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
                        if let anchor = payload.anchor { self.busy.pendingAnchor = anchor }
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
                case .appFocused(let payload):
                    // Track current app so findings tint only in their own
                    // context. Findings themselves are kept — switching back
                    // to the source app restores the tint, which matches the
                    // user's mental model ("I had something flagged in Notes
                    // and came back to it").
                    self.currentAppBundleId = payload.appBundleId
                    self.recomputeIndicatorState()
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
                    self.busy.hide()
                }
                self.recomputeIndicatorState()
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
        busy.teardown()
        caretPanel?.orderOut(nil)
        caretPanel = nil
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
        // While a finding is on screen, the indicator must persist — it is
        // the entire signal the user has. Skip the auto-hide bookkeeping
        // entirely; `recomputeIndicatorState` re-arms it when the finding
        // clears.
        if indicatorState.severity != nil { return }
        // Push the deadline out. If a hide task is already running, it will
        // observe the new deadline on its next wake and re-sleep — no need to
        // cancel and respawn a fresh `Task` per `caret.moved` event.
        let deadline = Date().addingTimeInterval(2)
        hideDeadline = deadline
        if hideTask != nil { return }
        hideTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let target = self.hideDeadline else { return }
                // Double-check on every wake — a finding may have landed
                // while we were sleeping, and the indicator must stay up.
                if self.indicatorState.severity != nil {
                    self.hideTask = nil
                    self.hideDeadline = nil
                    return
                }
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

    // MARK: - Busy loader orchestration
    //
    // The panel, ring, and glow live in `BusyLoaderPanel`. This section only
    // handles when to show/hide it and the watchdog that recovers a stuck
    // state — `busyDepth` and `busyWatchdog` are still owned here.

    /// Enter the "AI working" state: hide the caret indicator and ask the
    /// loader panel to come up. Anchor is taken from the latest
    /// `inferenceActivity` payload (set in `busy.pendingAnchor`), falling
    /// back to the most recent caret rect.
    private func enterBusy() {
        guard Self.indicatorEnabled else { return }
        // Cancel + clear so the next `scheduleAutoHide` after exitBusy spawns
        // a fresh task instead of seeing the stale (cancelled) reference.
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
        caretPanel?.orderOut(nil)
        lastCaretFrame = nil
        busy.show(at: lastCaretRect)
    }

    /// Leave the busy state: hide the loader and hand back to the caret indicator.
    private func exitBusy() {
        busyWatchdog?.cancel()
        busyWatchdog = nil
        busy.hide()
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
    /// strongest-severity finding wins the tint; findings are exposed
    /// severity-sorted for the hover popover. Also drives the indicator's
    /// visibility (must persist while a finding is active) and its
    /// pass-through behaviour (click-through when clean, interactive when a
    /// finding exists so hover/click events can reach the SwiftUI view).
    private func recomputeIndicatorState() {
        // Only findings that belong to the currently-focused app drive the
        // visible tint. A Notes finding shouldn't bleed into Safari/Warp —
        // but it stays in `activeFindings` so returning to Notes restores it.
        let visible = activeFindings.values.filter { f in
            currentAppBundleId == nil || f.appBundleId == currentAppBundleId
        }
        let highest = visible.max(by: { $0.severity < $1.severity })
        let wasActive = (indicatorState.severity != nil)
        let isActive = (highest != nil)

        indicatorState.findings = visible.sorted { $0.severity > $1.severity }
        indicatorState.severity = highest?.severity

        // Pass-through: idle = clicks fall through to the app; finding =
        // panel captures hover/click for the popover. `.statusBar` level
        // keeps it floating above target apps either way.
        caretPanel?.ignoresMouseEvents = !isActive
        caretPanel?.acceptsMouseMovedEvents = isActive

        if isActive {
            // A finding just lit up (or replaced a prior one). Make sure
            // the panel is visible at the last-known caret position — the
            // auto-hide may have already retired it during the few hundred
            // ms of classification latency.
            hideTask?.cancel()
            hideTask = nil
            hideDeadline = nil
            if let caret = lastCaretRect {
                showCaret(at: caret)
            } else {
                caretPanel?.orderFrontRegardless()
            }
        } else if wasActive {
            // The finding cleared. Resume the normal transient behaviour so
            // the indicator fades after the next idle period rather than
            // hanging around forever.
            scheduleAutoHide()
        }
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
    /// SwiftUI `.onHover` toggles this — kept for the dot's own hover
    /// affordance (a slight glow / shadow could read from this later).
    var isHovering: Bool = false
    /// Set when the user clicks the indicator; `IndicatorPopover` is bound
    /// to this so it appears anchored to the dot. Toggled back off when
    /// the user picks an action or clicks outside.
    var isShowingPopover: Bool = false
    /// Closure invoked when the user picks an action in the popover.
    /// `OverlayController` wires this to publish a `.findingActionRequested`
    /// event so the originating plugin can handle the intent — keeps the
    /// overlay layer ignorant of plugin internals.
    var onAction: ((Event.FindingDetected, Event.FindingActionRequested.Action) -> Void)?
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
@MainActor
struct HalenCaretIndicator: View {
    @AppStorage(OverlayController.dotStyleKey) private var dotStyle: String = "solid"
    /// Pass an empty `OverlayIndicatorState` for indicators that never need
    /// to tint (e.g. the busy-loader's centred logo).
    @Bindable var state: OverlayIndicatorState

    var body: some View {
        // Same 16×16 footprint always. The mark itself recolours when a
        // finding is active:
        //
        //  - Idle: the user's chosen mark style (solid/outline) renders
        //    verbatim from the pre-rendered PNG. Unchanged from the
        //    original implementation.
        //  - Finding: the solid mark renders as a SwiftUI template image
        //    tinted by `.foregroundStyle`. Switching to solid in the
        //    tinted state is deliberate — the outline asset has a white
        //    interior that template-rendering would also recolour
        //    (producing a flat red blob, no contrast). Tinting needs a
        //    single-colour silhouette, and solid is exactly that.
        //
        // The "preserve outline tint" arc requires a separate outline-only
        // template asset; tracked under UX-1 alongside the inline overlay.
        Group {
            if let severity = state.severity {
                tintedMark(color: Self.color(for: severity))
            } else {
                idleMark
            }
        }
        .frame(width: OverlayController.dotSize,
               height: OverlayController.dotSize)
        .contentShape(Rectangle())
        .onHover { hovering in
            state.isHovering = hovering
        }
        .onTapGesture {
            // Only meaningful when the indicator is tinted. Toggling lets
            // the user click again to dismiss without aiming for "outside".
            guard state.severity != nil else { return }
            state.isShowingPopover.toggle()
        }
        .popover(isPresented: Binding(
            get: { state.isShowingPopover && state.severity != nil },
            set: { state.isShowingPopover = $0 }
        ), arrowEdge: .leading) {
            IndicatorPopoverContent(state: state)
                .frame(width: 280)
        }
    }

    /// User-preferred idle mark — exactly the original rendering.
    private var idleMark: some View {
        let asset = dotStyle == "outline" ? "HalenOutline" : "HalenIndicator"
        return Group {
            if let img = NSImage(named: asset) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Circle().fill(Color.halenCobalt).padding(2)
            }
        }
    }

    /// Tinted finding mark — solid silhouette as a template image, recoloured
    /// by `.foregroundStyle`. Solid is forced (not the user's preference) so
    /// template rendering produces a clean coloured mark instead of an
    /// outline asset's filled blob.
    private func tintedMark(color: Color) -> some View {
        // Cast `.copy()` safely: `NSImage` conforms to `NSCopying`, so the
        // return is *contractually* an `NSImage`, but the underlying API
        // hands back `Any` — a force-cast here would trap if anything ever
        // returned a proxy. `as?` falls through to the coloured-circle
        // backup if that ever happens, which is the same fallback the asset-
        // missing branch uses below. The circle still draws at 16×16 in the
        // chosen severity colour so the user still sees the finding signal.
        Group {
            if let img = NSImage(named: "HalenIndicator"),
               let templated = img.copy() as? NSImage {
                templated.isTemplate = true
                return AnyView(
                    Image(nsImage: templated)
                        .resizable()
                        .interpolation(.high)
                        .foregroundStyle(color)
                )
            } else {
                return AnyView(Circle().fill(color).padding(2))
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

/// Popover content shown when the user clicks a tinted Halen caret
/// indicator. Lists every active finding by severity and offers the two
/// common actions — Looks fine (allowlist + dismiss) and Rephrase (the
/// plugin's rewrite path). Both publish a `.findingActionRequested` event
/// on the EventBus; the originating plugin owns the actual behaviour, so
/// this view stays plugin-agnostic.
@MainActor
private struct IndicatorPopoverContent: View {
    @Bindable var state: OverlayIndicatorState

    /// Focus targets inside the popover. `.rephrase` is the primary action;
    /// `.approve` is the muted secondary. We move focus to one of these on
    /// appear so VoiceOver / keyboard-only users land on a button instead of
    /// the popover container.
    private enum Field: Hashable { case rephrase, approve }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let top = state.findings.first {
                HStack(spacing: 8) {
                    Circle()
                        .fill(HalenCaretIndicator.color(for: top.severity))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(top.summary)
                        .font(.system(.callout, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
            }
            if state.findings.count > 1 {
                ForEach(state.findings.dropFirst(), id: \.id) { f in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(HalenCaretIndicator.color(for: f.severity))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(f.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 2)
                }
            }
            HStack(spacing: 8) {
                Button("Looks fine") {
                    invokeAction(.approve)
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .focused($focusedField, equals: .approve)
                .accessibilityLabel("Looks fine")
                .accessibilityHint("Dismiss this finding and remember the choice.")
                Spacer()
                // Custom-styled button — `.borderedProminent` over the
                // popover's `.regularMaterial` chrome renders as a faint
                // translucent gray with near-invisible white text in this
                // popover context. An explicit accent fill + white text
                // gives reliable contrast regardless of macOS appearance.
                Button {
                    invokeAction(.rephrase)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                        Text("Rephrase")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .focused($focusedField, equals: .rephrase)
                .accessibilityLabel("Rephrase")
                .accessibilityHint("Generate a rewritten version of the flagged text.")
            }
        }
        .padding(12)
        // Focus the primary action on appear — VoiceOver users otherwise land
        // on the popover container with no obvious next move. The brief hop
        // gives SwiftUI's NSHostingView time to finish becoming the focused
        // element before we redirect focus inward.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focusedField = .rephrase
        }
    }

    /// Fire the chosen action against the strongest-severity finding (the
    /// one shown as the headline) and dismiss the popover. Anything
    /// secondary listed below the headline is still cleared in bulk when
    /// the plugin processes the action — keeps the UX from forcing the
    /// user to interact with each finding individually.
    private func invokeAction(_ action: Event.FindingActionRequested.Action) {
        guard let top = state.findings.first else { return }
        state.onAction?(top, action)
        state.isShowingPopover = false
    }
}

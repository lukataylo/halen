import AppKit
import EQCore
import SwiftUI

/// A floating card that appears top-right when a call ends — where macOS
/// shows notifications, so it reads as one — without stealing focus from
/// whatever you're doing. Return saves, Esc skips, and it leaves on its own
/// after a few minutes if ignored.
@MainActor
final class RatingPanelController {
    weak var model: AppModel?
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    func present(_ id: UUID) {
        guard let model else { return }
        show(PostCallCard(id: id, onDone: { [weak self] in self?.close() }).environmentObject(model), dismissAfter: 240)
    }

    /// "Zoom is using the mic — listen?" for apps set to Ask first.
    func ask(_ call: CallDetector.Call) {
        guard let model else { return }
        show(AskCard(call: call, onDone: { [weak self] in self?.close() }).environmentObject(model), dismissAfter: 30)
    }

    private func show<V: View>(_ view: V, dismissAfter: TimeInterval) {
        close()
        // Borderless: no title bar, so no "forehead". The card draws its own
        // rounded material background; the window just carries the shadow.
        let p = KeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: view
            .background(.regularMaterial, in: .rect(cornerRadius: 16)))
        p.contentView = host
        let fit = host.fittingSize
        p.setFrame(NSRect(origin: .zero, size: fit), display: false)
        p.invalidateShadow()
        if let screen = NSScreen.main?.visibleFrame {
            // Tucked under the menu bar, top-right — where the eye already
            // goes for things that just happened.
            p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 10, y: screen.maxY - 6))
        }
        p.orderFrontRegardless()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            p.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        }
        panel = p
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dismissAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel?.isKeyWindow == false { self?.close() } }
        }
    }

    func close() {
        dismissTimer?.invalidate()
        panel?.close()
        panel = nil
    }
}

/// What you see when a call ends: three numbers, one takeaway, one control.
struct PostCallCard: View {
    let id: UUID
    var onDone: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var rating = 0.5
    @State private var touched = false
    @State private var note = ""

    var body: some View {
        if let r = model.session(id) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SourceIcon(bundleID: r.source, size: 16)
                    Text(r.title).font(.headline)
                    Text("\(max(1, Int(r.metrics.duration / 60))) min").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Skip", systemImage: "xmark", action: onDone)
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                        .help("Skip (Esc)")
                }

                HStack(spacing: 18) {
                    ForEach(Insights.Dimension.allCases, id: \.self) { d in
                        DotRing(value: d.score(r.effectiveScores).value, label: d.rawValue, size: 38, dots: 24, color: Palette.color(d))
                    }
                }
                .frame(maxWidth: .infinity)

                Group {
                    if let t = r.takeaway { Text(t) }
                    else if r.effectiveScores.clarity.value == nil { Text("Under 3 minutes of you speaking — too short to score.").foregroundStyle(.secondary) }
                    else { Text("Thinking…").foregroundStyle(.secondary) }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 54, alignment: .topLeading)   // takeaway arriving doesn't resize the card
                .animation(.easeOut, value: r.takeaway)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        DotLabel("How did it go?", size: 10)
                        Spacer()
                        Text(touched ? Rating.word(rating) : "").font(Dot.font(13)).contentTransition(.numericText())
                    }
                    DotSlider(value: $rating.onSet { touched = true }, touched: touched)
                }

                HStack(spacing: 8) {
                    TextField("Note (optional)", text: $note)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { model.rate(id, rating, note: note); onDone() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!touched)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}

/// Prompt for apps set to "Ask first".
struct AskCard: View {
    let call: CallDetector.Call
    var onDone: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(bundleID: call.bundleID, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(appName) is using the mic").font(.callout.weight(.medium))
                Text("Listen to your side?").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not Now", action: onDone).keyboardShortcut(.cancelAction)
            Button("Listen") { onDone(); Task { await model.start(source: call.bundleID) } }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 340)
    }

    private var appName: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: call.bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? call.appName
    }
}

extension Binding where Value: Equatable {
    /// Runs `action` only on a real change (SwiftUI sometimes writes back the
    /// same value, which shouldn't count as the user rating).
    func onSet(_ action: @escaping () -> Void) -> Binding {
        Binding(get: { wrappedValue }, set: { if $0 != wrappedValue { wrappedValue = $0; action() } })
    }
}

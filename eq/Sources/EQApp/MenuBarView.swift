import EQCore
import SwiftUI

/// The menu bar popover: today at a glance, what's happening now, and the
/// one thing that needs you (rating the last call, or setting up).
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var rating = 0.5
    @State private var touched = false
    @StateObject private var permissions = Permissions()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 18) {
                ForEach(Insights.Dimension.allCases, id: \.self) { d in
                    DotRing(value: Insights.score(d, model.today), label: d.rawValue, size: 40, dots: 24, color: Palette.color(d))
                }
            }
            .frame(maxWidth: .infinity)

            if permissions.microphone == .denied {
                banner("Microphone access is off", detail: "Halen can't hear you.", action: "Open Settings") { Permissions.open("Privacy_Microphone") }
            }
            if model.voiceMismatch, model.state == .idle {
                banner("Halen ignored most of that call", detail: "New mic or headphones? Record your voice again.", action: "Record") { openWindow(id: "voice"); NSApp.activate() }
            }
            if model.voicePrint == nil, model.state == .idle { setupCard }
            if let r = model.lastUnrated, model.state == .idle { rateCard(r) }

            if let e = model.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                status
                Spacer()
                switch model.state {
                case .idle:
                    if model.pausedUntil != nil {
                        Button("Resume") { model.pause(until: nil) }.controlSize(.small)
                    } else {
                        Menu("Listen Now") {
                            Button("Pause for 1 Hour") { model.pause(until: .now.addingTimeInterval(3600)) }
                            Button("Pause Until Tomorrow") { model.pause(until: Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))) }
                        } primaryAction: { Task { await model.start(source: nil) } }
                        .controlSize(.small).fixedSize()
                        .help("Listen now, or hold the arrow to pause Halen for private calls")
                    }
                case .listening(_, let since):
                    Text(since, style: .timer).font(Dot.font(13)).monospacedDigit().foregroundStyle(.secondary)
                case .starting, .analysing:
                    ProgressView().controlSize(.small)
                }
            }
            if model.isListening {
                VStack(spacing: 8) {
                    LiveWave(live: model.live)
                    HStack(spacing: 8) {
                        Button("Discard", systemImage: "trash") { Task { await model.stop(discard: true) } }
                            .labelStyle(.iconOnly).controlSize(.small)
                            .help("Stop and keep nothing from this call")
                        Button("Stop") { Task { await model.stop() } }.controlSize(.small)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: model.isListening)
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle:
            if let c = model.detectedCall, c.isBrowser {
                Label("Browser is using the mic", systemImage: "globe").font(.callout)
            } else if let until = model.pausedUntil {
                Label("Paused until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "pause.circle").font(.callout)
            } else {
                Label("Waiting for a call", systemImage: "moon.zzz").font(.callout).foregroundStyle(.secondary)
            }
        case .starting:
            Label("Getting ready…", systemImage: "hourglass").font(.callout)
        case .listening(let src, _):
            HStack(spacing: 6) {
                Circle().fill(Palette.clarity).frame(width: 7, height: 7)
                    .phaseAnimator([1.0, 0.35]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.9) }
                Text(model.voicePrint == nil ? "Listening" : "Hearing only you").font(.callout)
                SourceIcon(bundleID: src, size: 14)
            }
            .help(model.voicePrint == nil ? "Voice check is off — other voices near your mic may be included." : "Voice check is on.")
        case .analysing:
            Label("Analysing · audio discarded", systemImage: "sparkles").font(.callout)
        }
    }

    private func banner(_ title: String, detail: String, action: String, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action, action: run).controlSize(.small)
        }
        .padding(8)
        .dotCard()
    }

    private var setupCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.wave.2")
            VStack(alignment: .leading, spacing: 0) {
                Text("Voice check is off").font(.callout.weight(.medium))
                Text("Only you are heard · 30 s").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set Up") { openWindow(id: "voice"); NSApp.activate() }.controlSize(.small)
        }
        .padding(8)
        .dotCard()
    }

    private func rateCard(_ r: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                DotLabel("Rate \(r.title) \(r.startedAt.formatted(date: .omitted, time: .shortened))", size: 11)
                Spacer()
                Text(touched ? Rating.word(rating) : "").font(Dot.font(12))
                Button("Save") { model.rate(r.id, rating, note: nil); touched = false; rating = 0.5 }
                    .controlSize(.small)
                    .opacity(touched ? 1 : 0)      // reserve the space: no jump
                    .disabled(!touched)
            }
            .frame(height: 22)
            DotSlider(value: $rating.onSet { touched = true }, touched: touched)
        }
        .padding(8)
        .dotCard()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow("Open Halen", shortcut: "O") { openWindow(id: "main"); NSApp.activate() }
            MenuRow("Settings…", shortcut: ",") { openSettings(); NSApp.activate() }
            if updater.isAvailable {
                MenuRow("Check for Updates…", shortcut: "U") { updater.checkForUpdates(); NSApp.activate() }
                    .disabled(!updater.canCheck)
            }
            MenuRow("Quit Halen", shortcut: "Q") { NSApp.terminate(nil) }
        }
    }
}

/// Menu-style row: full-width, highlights on hover, shortcut on the right —
/// the way native menu bar extras look.
struct MenuRow: View {
    let title: String, shortcut: Character, action: () -> Void
    @State private var hover = false
    init(_ title: String, shortcut: Character, action: @escaping () -> Void) {
        self.title = title; self.shortcut = shortcut; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text("⌘\(String(shortcut).uppercased())").foregroundStyle(.secondary).font(.callout)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(.rect)
            .background(hover ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .onHover { hover = $0 }
    }
}

/// Observes only the live meter, so 10 Hz updates redraw just this.
private struct LiveWave: View {
    @ObservedObject var live: LiveMeter
    var body: some View {
        VStack(spacing: 3) {
            HairlineWave(you: live.you, them: live.them)
            HStack {
                Text("you")
                Spacer()
                if live.them != nil { Text("them") }
            }
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
        }
    }
}

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 18) {
                ForEach(Insights.Dimension.allCases, id: \.self) { d in
                    DotRing(value: Insights.score(d, model.today), label: d.rawValue, size: 40, dots: 24, color: Palette.color(d))
                }
            }
            .frame(maxWidth: .infinity)

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
                    Button("Listen Now") { Task { await model.start(source: nil) } }
                        .controlSize(.small)
                        .help("Listen to an in-person conversation or a call Halen EQ didn't spot")
                case .listening:
                    Button("Stop") { Task { await model.stop() } }.controlSize(.small)
                case .starting, .analysing:
                    ProgressView().controlSize(.small)
                }
            }
            if model.isListening {
                LiveWave(live: model.live)
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
            } else {
                Label("Waiting for a call", systemImage: "moon.zzz").font(.callout).foregroundStyle(.secondary)
            }
        case .starting:
            Label("Getting ready…", systemImage: "hourglass").font(.callout)
        case .listening(let src, let since):
            HStack(spacing: 6) {
                SourceIcon(bundleID: src, size: 16)
                Text("Hearing only you").font(.callout)
                Text(since, style: .timer).font(Dot.font(14)).monospacedDigit()
            }
            .help(model.voicePrint == nil ? "Voice check is off — other voices near your mic may be included." : "Voice check is on.")
        case .analysing:
            Label("Analysing · audio discarded", systemImage: "sparkles").font(.callout)
        }
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
            MenuRow("Open Halen EQ", shortcut: "O") { openWindow(id: "main"); NSApp.activate() }
            MenuRow("Settings…", shortcut: ",") { openSettings(); NSApp.activate() }
            if updater.isAvailable {
                MenuRow("Check for Updates…", shortcut: "U") { updater.checkForUpdates(); NSApp.activate() }
                    .disabled(!updater.canCheck)
            }
            MenuRow("Quit Halen EQ", shortcut: "Q") { NSApp.terminate(nil) }
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
        VStack(alignment: .leading, spacing: 4) {
            DotWaveform(you: live.you, them: live.them)
            HStack {
                DotLabel("You", size: 9)
                Spacer()
                if live.them != nil { DotLabel("Them · level only", size: 9) }
            }
        }
    }
}

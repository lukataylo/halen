import SwiftUI
import AppKit

/// App-level settings: Accessibility permission status, live Ollama connection probe
/// (so the user can see at a glance whether their local Gemma 4 daemon is reachable
/// and which models are loaded), and About metadata. Sits on the same push-navigation
/// stack as plugin detail views.
struct SettingsView: View {
    @Bindable var state: AppState
    let onBack: () -> Void

    @State private var ollamaStatus: OllamaStatus = .checking
    @State private var pollTask: Task<Void, Never>?
    @AppStorage(OverlayController.showDotKey) private var showCaretIndicator: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    accessibilityCard
                    overlayCard
                    aiCard
                    aboutCard
                }
                .padding(12)
            }
        }
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Plugins")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .overlay(
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text("Settings")
                    .font(.system(.callout, weight: .semibold))
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Cards

    private var accessibilityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Accessibility")
                HStack(spacing: 10) {
                    statusDot(state.permissionStatus == .granted ? .ok : .warning)
                    Text(accessibilityStatusText)
                        .font(.system(.callout))
                    Spacer()
                    Button("Open Settings") {
                        AXPermissions.openSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("Required for cursor tracking and inline corrections. All processing stays on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var overlayCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Cursor overlay")
                HStack(alignment: .center, spacing: 12) {
                    overlayPreview
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Halen indicator near cursor")
                            .font(.system(.callout, weight: .medium))
                        Text("A small Halen mark appears beside your caret while you type. Turn off if it gets in the way.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: $showCaretIndicator)
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                }
            }
        }
    }

    private var overlayPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
            if let img = NSImage(named: "HalenMenubar") {
                let templated: NSImage = {
                    img.isTemplate = true
                    return img
                }()
                Image(nsImage: templated)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(Color(red: 0, green: 0.30, blue: 0.99))
                    .frame(width: 18, height: 18)
            } else {
                Circle()
                    .fill(Color(red: 0, green: 0.30, blue: 0.99))
                    .frame(width: 12, height: 12)
            }
        }
        .frame(width: 40, height: 40)
    }

    private var aiCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardLabel("Local AI")
                    Spacer()
                    Button {
                        Task { await refreshOllama() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    statusDot(ollamaStatusKind)
                    Text(ollamaStatusText)
                        .font(.system(.callout))
                    Spacer()
                }

                if case .connected(let models) = ollamaStatus, !models.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(models, id: \.self) { model in
                            HStack(spacing: 6) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text(model)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                if case .unavailable = ollamaStatus {
                    Text("Start Ollama with `ollama serve` to enable Gemma-backed plugins like Sentiment Guard.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("About")
                HStack(alignment: .firstTextBaseline) {
                    Text("Halen")
                        .font(.system(.body, weight: .semibold))
                    Text("v0.1.0")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/lukataylo/halen")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text("github.com/lukataylo/halen")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Text("Local-first writing agent for macOS. Uses your local Gemma 4 instance for tone, typo, and rewrite tasks — no text leaves this device.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Helpers

    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private enum StatusKind { case ok, warning, error }

    private func statusDot(_ kind: StatusKind) -> some View {
        let color: Color = {
            switch kind {
            case .ok: return Color(red: 0.20, green: 0.78, blue: 0.35)
            case .warning: return Color.orange
            case .error: return Color.red
            }
        }()
        return ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 14, height: 14)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
    }

    private var accessibilityStatusText: String {
        switch state.permissionStatus {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .unknown: return "Checking…"
        }
    }

    // MARK: - Ollama probe

    enum OllamaStatus: Equatable {
        case checking
        case connected(models: [String])
        case unavailable
    }

    private var ollamaStatusKind: StatusKind {
        switch ollamaStatus {
        case .checking: return .warning
        case .connected: return .ok
        case .unavailable: return .error
        }
    }

    private var ollamaStatusText: String {
        switch ollamaStatus {
        case .checking:    return "Checking localhost:11434…"
        case .connected:   return "Connected to localhost:11434"
        case .unavailable: return "Not reachable on localhost:11434"
        }
    }

    private func startPolling() {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refreshOllama()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func refreshOllama() async {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                ollamaStatus = .unavailable
                return
            }
            struct TagsResponse: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            let gemmas = decoded.models
                .map(\.name)
                .filter { $0.lowercased().contains("gemma") }
                .sorted()
            ollamaStatus = .connected(models: gemmas)
        } catch {
            ollamaStatus = .unavailable
        }
    }
}

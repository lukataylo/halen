import SwiftUI
import AppKit

/// App-level settings: Accessibility permission status, the inference backend
/// picker (priority order + live availability of Apple Intelligence / Ollama /
/// future local runtimes), and About metadata. Sits on the same push-navigation
/// stack as plugin detail views.
struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable var inferenceSettings: InferenceSettings
    let router: RouterInferenceClient
    @Bindable var modelDownloader: ModelDownloader
    let onBack: () -> Void

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
                    builtInModelCard
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
            if let img = NSImage(named: "HalenIndicator") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            } else {
                Circle()
                    .fill(Color.halenCobalt)
                    .frame(width: 12, height: 12)
            }
        }
        .frame(width: 40, height: 40)
    }

    private var aiCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardLabel("Inference backends")
                    Spacer()
                    Button {
                        Task { await router.refreshAvailability() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                ForEach(Array(inferenceSettings.preferenceOrder.enumerated()), id: \.element) { index, kind in
                    backendRow(kind: kind, index: index)
                }

                Text("Halen tries backends in this order — the first available one handles each request. Reorder with the arrows.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func backendRow(kind: BackendKind, index: Int) -> some View {
        let availability = inferenceSettings.availability[kind]
        let statusKind: StatusKind
        let detail: String
        switch availability {
        case .available:
            statusKind = .ok
            detail = "Available"
        case .unavailable(let reason):
            statusKind = .error
            detail = reason
        case nil:
            statusKind = .warning
            detail = "Checking…"
        }
        return HStack(spacing: 10) {
            statusDot(statusKind)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                    .font(.system(.callout, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            VStack(spacing: 2) {
                Button {
                    moveBackend(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                Button {
                    moveBackend(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(index == inferenceSettings.preferenceOrder.count - 1)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func moveBackend(from: Int, to: Int) {
        guard to >= 0, to < inferenceSettings.preferenceOrder.count else { return }
        var order = inferenceSettings.preferenceOrder
        let item = order.remove(at: from)
        order.insert(item, at: to)
        inferenceSettings.preferenceOrder = order
    }

    private var builtInModelCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Built-in model")

                HStack(spacing: 10) {
                    statusDot(modelStatusKind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(modelStatusTitle)
                            .font(.system(.callout, weight: .medium))
                        Text(modelStatusDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    modelActionButton
                }

                if case let .downloading(fraction, bytes, total) = modelDownloader.state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    Text("\(formatBytes(bytes)) of \(formatBytes(total)) (\(Int(fraction * 100))%)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("The 770 MB Gemma 3 1B GGUF runs locally as a fallback when Apple Intelligence isn't available. Downloads on demand into Application Support — never bundled in the .app unless you build with BUNDLE_MODEL=1.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var modelActionButton: some View {
        switch modelDownloader.state {
        case .notDownloaded:
            Button("Download") { modelDownloader.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading:
            Button("Cancel") { modelDownloader.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .verifying, .installing:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Button("Remove") { modelDownloader.removeDownloaded() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .failed:
            Button("Retry") { modelDownloader.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var modelStatusKind: StatusKind {
        switch modelDownloader.state {
        case .ready:                              return .ok
        case .downloading, .verifying, .installing: return .warning
        case .notDownloaded:                       return .warning
        case .failed:                              return .error
        }
    }

    private var modelStatusTitle: String {
        switch modelDownloader.state {
        case .notDownloaded: return "Not downloaded"
        case .downloading:   return "Downloading…"
        case .verifying:     return "Verifying…"
        case .installing:    return "Installing…"
        case .ready:         return "Ready"
        case .failed:        return "Download failed"
        }
    }

    private var modelStatusDetail: String {
        switch modelDownloader.state {
        case .notDownloaded:
            return "Apple Intelligence (if available) covers most requests. Download Gemma for the fallback."
        case .downloading(_, let bytes, let total):
            return "\(formatBytes(bytes)) of \(formatBytes(total))"
        case .verifying:
            return "Checking SHA-256 against the pinned hash."
        case .installing:
            return "Moving into Application Support."
        case .ready:
            return "Gemma 3 1B Q4_K_M, ~770 MB on disk."
        case .failed(let message):
            return message
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
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

    // MARK: - Backend polling

    private func startPolling() {
        // `onAppear` can fire more than once for the same view — cancel any
        // existing loop so we don't leak a second infinite poll task.
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await router.refreshAvailability()
                // 30 s, not 10 — each refresh re-probes every backend, including
                // a 1 s blocking call to localhost:11434 if Ollama isn't running.
                // The user can hit the Refresh button for an immediate update.
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

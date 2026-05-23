import SwiftUI
import AppKit

/// App-level settings: Accessibility permission status, the inference backend
/// picker (priority order + live availability of Apple Intelligence / Ollama /
/// future local runtimes), and About metadata. Sits on the same push-navigation
/// stack as plugin detail views.
@MainActor
struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable var inferenceSettings: InferenceSettings
    let router: RouterInferenceClient
    @Bindable var modelDownloader: ModelDownloader
    let webSocketBridge: WebSocketBridge?
    @Bindable var launchAtLogin: LaunchAtLoginController
    let onBack: () -> Void

    @State private var pollTask: Task<Void, Never>?
    @State private var confirmingModelRemove = false
    @State private var confirmingTokenRotate = false
    @State private var tokenCopied = false
    /// Owned at view scope — the data is cheap to re-query and shouldn't
    /// be retained across menubar-popup close/reopen where it could go
    /// stale under us. `refresh()` runs on every `onAppear`.
    @State private var permissions = SystemPermissionsModel()
    @AppStorage(OverlayController.showDotKey) private var showCaretIndicator: Bool = true
    @AppStorage(OverlayController.dotStyleKey) private var overlayDotStyle: String = "solid"
    @AppStorage(OverlayController.underlineEnabledKey) private var inlineUnderlines: Bool = false
    /// Two-way binding to the WS bridge's enabled preference. Toggling
    /// here also calls into the bridge to actually start/stop it live.
    @AppStorage(WebSocketBridge.enabledKey) private var webSocketEnabled: Bool = true
    /// Persisted Ollama endpoint. The TextField edits `ollamaURLDraft` and
    /// only writes through to this key on commit — typing "http://localh"
    /// mid-edit shouldn't put a half-URL into UserDefaults.
    @AppStorage(OllamaSettings.baseURLKey) private var ollamaURLStored: String = OllamaSettings.defaultBaseURLString
    @State private var ollamaURLDraft: String = OllamaSettings.defaultBaseURLString
    @State private var ollamaURLInvalid: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    startupCard
                    permissionsCard
                    overlayCard
                    aiCard
                    ollamaCard
                    builtInModelCard
                    if webSocketBridge != nil { webSocketCard }
                    aboutCard
                }
                .padding(12)
            }
        }
        .onAppear {
            startPolling()
            // Refresh anything macOS doesn't push notifications for — the
            // user might have toggled launch-at-login or a system
            // permission between visits.
            launchAtLogin.refresh()
            permissions.refresh()
            // Seed the in-progress draft from the persisted value. Without
            // this the TextField would render empty on first open and the
            // user would think no URL was configured.
            ollamaURLDraft = ollamaURLStored
        }
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

    private var startupCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Startup")
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "power.dotted")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(.callout, weight: .medium))
                        Text(startupDetailText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: launchAtLoginBinding)
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                        // .requiresApproval means the user has disabled the
                        // registration under System Settings; the toggle alone
                        // can't re-enable it. Disabling the control prevents
                        // a confusing "toggle does nothing" experience — the
                        // deep-link button below carries the action.
                        .disabled(launchAtLogin.requiresApproval)
                }
                if launchAtLogin.requiresApproval {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("Disabled under System Settings → Login Items. Re-enable there.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") {
                            LaunchAtLoginController.openLoginItemsSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if let error = launchAtLogin.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Two-way binding for the launch-at-login toggle. The getter reads the
    /// effective status from the controller; the setter delegates to
    /// `setEnabled(_:)` which handles errors and refresh in one shot.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var startupDetailText: String {
        if launchAtLogin.requiresApproval {
            return "Disabled by the system. Re-enable from Login Items."
        }
        return launchAtLogin.isEnabled
            ? "Halen will open when you log in."
            : "Halen will only run when you launch it."
    }

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Permissions")
                ForEach(SystemPermission.allCases) { permission in
                    permissionRow(permission)
                    if permission != SystemPermission.allCases.last {
                        Divider().padding(.leading, 30)
                    }
                }
                Text("Halen runs entirely on this Mac. Granting a permission lets a specific feature work; revoking it disables only that feature.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func permissionRow(_ permission: SystemPermission) -> some View {
        let grant = permissions.grants[permission] ?? .checking
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: permission.iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(permission.displayName)
                        .font(.system(.callout, weight: .medium))
                    statusDot(statusKind(for: grant))
                    Text(label(for: grant))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(permission.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Open") {
                permission.openSystemSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func statusKind(for grant: PermissionGrant) -> StatusKind {
        switch grant {
        case .granted:      return .ok
        // Not-requested isn't an alarm — it's just "Halen hasn't asked yet."
        // The relevant plugin will trigger the prompt on first use.
        case .notRequested: return .neutral
        case .denied:       return .warning
        case .checking:     return .neutral
        }
    }

    private func label(for grant: PermissionGrant) -> String {
        switch grant {
        case .granted:      return "Granted"
        case .denied:       return "Not granted"
        case .notRequested: return "Not requested"
        case .checking:     return "Checking…"
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

                // Style picker — only relevant when the indicator is on.
                if showCaretIndicator {
                    Divider().opacity(0.4)
                    HStack(spacing: 10) {
                        Text("Style")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $overlayDotStyle) {
                            Text("Solid").tag("solid")
                            Text("Outline").tag("outline")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        Spacer()
                    }

                    // Preview-feature toggle: when ON, a severity-coloured
                    // underline strip is drawn under the flagged paragraph
                    // in addition to the cursor-indicator tint. Per-glyph
                    // (Grammarly-style) underlines need an AX-overlay
                    // system that's tracked separately — this v1 is the
                    // scaffold + the visible affordance.
                    Divider().opacity(0.4)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inline underlines")
                                .font(.system(size: 12, weight: .medium))
                            Text("Preview · draws a coloured strip under the flagged paragraph. Works best in Notes and TextEdit; coverage in browsers and Electron apps is rougher.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $inlineUnderlines)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
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
            if let img = NSImage(named: overlayDotStyle == "outline" ? "HalenOutline" : "HalenIndicator") {
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
        // When Apple Intelligence is specifically *off* (vs unsupported
        // hardware), surface a one-click jump to the right System Settings
        // pane — the user has already said "I want this on", asking them
        // to dig through System Settings is friction they shouldn't pay.
        let showAppleAISettingsButton: Bool = {
            guard kind == .appleFoundationModels,
                  case .unavailable(let reason) = availability else { return false }
            return reason.localizedCaseInsensitiveContains("turned off")
                || reason.localizedCaseInsensitiveContains("not enabled")
        }()
        return HStack(spacing: 10) {
            statusDot(statusKind)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                    .font(.system(.callout, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showAppleAISettingsButton {
                    Button("Open System Settings → Apple Intelligence") {
                        // x-apple-systempreferences URLs are stable across
                        // macOS versions; the AppleIntelligence pane is the
                        // canonical anchor.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.appleintelligence") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
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

    // MARK: - Ollama card

    private var ollamaCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Ollama")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("http://localhost:11434", text: $ollamaURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .autocorrectionDisabled(true)
                            .textContentType(.URL)
                            .onSubmit { commitOllamaURL() }
                            // Mirror upstream changes (Reset button, or a
                            // change made from another Settings instance)
                            // into the in-progress draft so the field stays
                            // in sync without a manual reload.
                            .onChange(of: ollamaURLStored) { _, new in
                                ollamaURLDraft = new
                                ollamaURLInvalid = false
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(ollamaURLInvalid ? Color.red : Color.clear,
                                            lineWidth: 1)
                            )
                        Button {
                            commitOllamaURL()
                        } label: {
                            Text("Save")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(ollamaURLDraft == ollamaURLStored)
                        Button {
                            ollamaURLStored = OllamaSettings.defaultBaseURLString
                            ollamaURLDraft = OllamaSettings.defaultBaseURLString
                            ollamaURLInvalid = false
                            Task { await router.refreshAvailability() }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reset to \(OllamaSettings.defaultBaseURLString)")
                    }
                }

                ollamaStatusLine

                Text("Where Halen sends Ollama requests. Change this if you've started `ollama serve` on a non-default port (`OLLAMA_HOST=…`). The Built-in model and Apple Intelligence backends are unaffected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// Sub-row under the URL field: validation error if the draft is bad,
    /// otherwise a "loopback / remote" indicator describing the saved URL.
    @ViewBuilder
    private var ollamaStatusLine: some View {
        if ollamaURLInvalid {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text("Not a valid http/https URL with a host.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if let url = OllamaSettings.validate(ollamaURLStored) {
            HStack(spacing: 6) {
                let loopback = OllamaSettings.isLoopback(url)
                statusDot(loopback ? .ok : .warning)
                Text(loopback
                     ? "Loopback — requests stay on this Mac."
                     : "Remote host — requests leave this Mac. Halen markets itself as local-first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Validate the in-progress draft. On success, write to UserDefaults and
    /// kick a fresh availability probe so the backends card updates
    /// immediately. On failure, flag the field; the user keeps editing.
    private func commitOllamaURL() {
        guard OllamaSettings.validate(ollamaURLDraft) != nil else {
            ollamaURLInvalid = true
            return
        }
        ollamaURLInvalid = false
        // Normalize the stored form (trimmed) so the badge state and the
        // backend agree on what's persisted, then sync the draft so the
        // Save button correctly reads as "no pending changes" and the
        // user doesn't see trailing whitespace.
        let normalized = ollamaURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        ollamaURLStored = normalized
        ollamaURLDraft = normalized
        Task { await router.refreshAvailability() }
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

                Text("The 4.72 GB Gemma 4 E4B GGUF runs locally as a fallback when Apple Intelligence isn't available. Downloads on demand into Application Support — never bundled in the .app unless you build with BUNDLE_MODEL=1.")
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
            Button("Remove") { confirmingModelRemove = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog("Delete the downloaded Gemma 4 E4B model?",
                                    isPresented: $confirmingModelRemove,
                                    titleVisibility: .visible) {
                    Button("Delete (\(formatBytes(modelDownloader.expectedSize)))",
                           role: .destructive) {
                        modelDownloader.removeDownloaded()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll need to re-download the model the next time the bundled fallback is requested.")
                }
        case .failed:
            Button("Retry") { modelDownloader.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var modelStatusKind: StatusKind {
        switch modelDownloader.state {
        case .ready:                                return .ok
        case .downloading, .verifying, .installing: return .warning
        // Not downloaded is the *default* on a fresh install — Apple Intelligence
        // covers most requests on its own, so a missing local fallback is not an
        // alarm condition. Neutral, not warning.
        case .notDownloaded:                         return .neutral
        case .failed:                                return .error
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
            return "Gemma 4 E4B IQ4_XS, ~4.72 GB on disk."
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

    // MARK: - WebSocket bridge card

    @ViewBuilder
    private var webSocketCard: some View {
        if let bridge = webSocketBridge {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        cardLabel("Browser & companion bridge")
                        Spacer()
                        Toggle("", isOn: $webSocketEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.regular)
                            .labelsHidden()
                            .onChange(of: webSocketEnabled) { _, newValue in
                                // Live start/stop so the user doesn't have to
                                // restart Halen for the toggle to take effect.
                                if newValue { bridge.start() } else { bridge.stop() }
                            }
                    }
                    HStack(spacing: 10) {
                        statusDot(bridge.isListening ? .ok : .neutral)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bridge.isListening
                                 ? "127.0.0.1:\(WebSocketBridge.defaultPort)"
                                 : "Off")
                                .font(.system(.callout, design: .monospaced))
                            Text(bridgeStatusDetail(bridge))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    Text("Halen exposes a JSON-RPC bridge on loopback so the browser extension (and future companions) can report typing in fields macOS Accessibility can't reach — Slack, Discord, Gmail, Docs.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 2)

                    HStack(spacing: 8) {
                        Text("Pairing token")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(tokenCopied ? "Copied!" : "Copy") {
                            if let token = BridgeTokenStore.tokenOrCreate() {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(token, forType: .string)
                                tokenCopied = true
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1.5))
                                    tokenCopied = false
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Regenerate") { confirmingTokenRotate = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                            .confirmationDialog("Regenerate the bridge token?",
                                                isPresented: $confirmingTokenRotate,
                                                titleVisibility: .visible) {
                                Button("Regenerate", role: .destructive) {
                                    _ = BridgeTokenStore.regenerate()
                                    // Drop every connected client — they'll
                                    // need to re-pair with the new token.
                                    bridge.stop()
                                    if webSocketEnabled { bridge.start() }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Every paired client (browser extension, companion apps) will need to re-enter the new token. Use this if you think the current token has leaked.")
                            }
                    }
                    Text("Browser extension: open its popup, paste this token, click Save.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func bridgeStatusDetail(_ bridge: WebSocketBridge) -> String {
        guard bridge.isListening else {
            return "Browser extension and other loopback clients won't connect while off."
        }
        switch bridge.clientCount {
        case 0:  return "Listening — no clients connected."
        case 1:  return "1 client connected."
        default: return "\(bridge.clientCount) clients connected."
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

    private enum StatusKind { case ok, warning, error, neutral }

    private func statusDot(_ kind: StatusKind) -> some View {
        let color: Color = {
            switch kind {
            case .ok:      return Color(red: 0.20, green: 0.78, blue: 0.35)
            case .warning: return Color.orange
            case .error:   return Color.red
            case .neutral: return Color.secondary
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

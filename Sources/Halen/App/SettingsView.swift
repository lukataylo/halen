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
    /// Opt-in downloader for the dedicated compaction model (Qwen3-4B-2507).
    /// Surfaced as its own Inference card; not started until the user asks.
    @Bindable var compactionDownloader: ModelDownloader
    let webSocketBridge: WebSocketBridge?
    @Bindable var launchAtLogin: LaunchAtLoginController
    /// Per-app tone profile store + the in-memory recently-focused-apps
    /// list. Both owned by AppCoordinator (the store persists per-app
    /// tones, the recents drive the editor's "apps you've used" picker).
    /// Surfaced here as a Settings → App tone profiles card with a sheet
    /// for the actual editor.
    @Bindable var toneProfileStore: AppToneProfileStore
    @Bindable var recentApps: RecentAppsModel
    /// Process-wide registry of hotkey conflicts. Observed so the warning
    /// card appears/disappears live as plugins are toggled on or off.
    @Bindable var hotkeyConflicts: HotkeyConflictRegistry
    let onBack: () -> Void
    /// Re-trigger the first-run walkthrough. Wired by `HalenCenterView`
    /// down to `AppCoordinator.onboardingWindow.presentAgain()`. Surfaced
    /// in the About card.
    let onRunSetupAgain: () -> Void
    /// Sparkle wrapper. About card uses this for the "Check for Updates"
    /// action and to hide the button entirely when SUFeedURL/SUPublicEDKey
    /// aren't configured (dev builds).
    let updater: UpdaterController

    @State private var pollTask: Task<Void, Never>?
    @State private var confirmingModelRemove = false
    @State private var confirmingCompactionRemove = false
    @State private var confirmingTokenRotate = false
    @State private var tokenCopied = false
    /// Owned at view scope — the data is cheap to re-query and shouldn't
    /// be retained across menubar-popup close/reopen where it could go
    /// stale under us. `refresh()` runs on every `onAppear`.
    @State private var permissions = SystemPermissionsModel()
    @AppStorage(OverlayController.showDotKey) private var showCaretIndicator: Bool = true
    @AppStorage(OverlayController.dotStyleKey) private var overlayDotStyle: String = "solid"
    /// Two-way binding to the WS bridge's enabled preference. Toggling
    /// here also calls into the bridge to actually start/stop it live.
    @AppStorage(WebSocketBridge.enabledKey) private var webSocketEnabled: Bool = true
    /// Persisted Ollama endpoint. The TextField edits `ollamaURLDraft` and
    /// only writes through to this key on commit — typing "http://localh"
    /// mid-edit shouldn't put a half-URL into UserDefaults.
    @AppStorage(OllamaSettings.baseURLKey) private var ollamaURLStored: String = OllamaSettings.defaultBaseURLString
    @State private var ollamaURLDraft: String = OllamaSettings.defaultBaseURLString
    @State private var ollamaURLInvalid: Bool = false
    @State private var presentingAppTonesEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    startupCard
                    permissionsCard
                    overlayCard
                    appTonesCard
                    aiCard
                    ollamaCard
                    builtInModelCard
                    compactionModelCard
                    if webSocketBridge != nil { webSocketCard }
                    hotkeyConflictCard
                    aboutCard
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $presentingAppTonesEditor) {
            // Wrap the existing per-app tone editor in a sheet so it
            // gets its own scroll context (the editor's body uses a
            // ScrollView; nesting that inside SettingsView's ScrollView
            // would be a UX regression).
            VStack(spacing: 0) {
                HStack {
                    Text("App tone profiles")
                        .font(.system(.headline))
                    Spacer()
                    Button("Done") { presentingAppTonesEditor = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                ToneProfilesDetailView(store: toneProfileStore, recentApps: recentApps)
            }
            .frame(minWidth: 480, minHeight: 420)
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
                    // Semantic font + explicit weight so the back affordance scales
                    // with Larger Accessibility Sizes; the old size: 12 was frozen.
                    Image(systemName: "chevron.left")
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text("Plugins")
                        .font(.callout)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Plugins")
            .accessibilityHint("Returns to the plugin marketplace list.")
            Spacer()
        }
        .overlay(
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.callout)
                    .fontWeight(.medium)
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
                    // Title3 fits a leading row icon at default text scale and
                    // continues to grow with Larger Accessibility Sizes.
                    Image(systemName: "power.dotted")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(.callout, weight: .medium))
                        Text(startupDetailText)
                            .font(.caption)
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
                        // Switch has no visible Toggle label, so VoiceOver
                        // needs an explicit one.
                        .accessibilityLabel("Launch Halen at login")
                        .accessibilityHint("Adds Halen to your Login Items so it opens automatically when you sign in.")
                }
                if launchAtLogin.requiresApproval {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("Disabled under System Settings → Login Items. Re-enable there.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") {
                            LaunchAtLoginController.openLoginItemsSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Opens System Settings → General → Login Items so you can re-enable Halen.")
                    }
                }
                if let error = launchAtLogin.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.caption)
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
            return "Turn on in System Settings → General → Login Items."
        }
        return launchAtLogin.isEnabled
            ? "Opens at login."
            : "Opens only when you launch it."
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
                Text("Halen runs locally. Each permission controls one feature.")
                    .font(.caption)
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
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(permission.displayName)
                        .font(.system(.callout, weight: .medium))
                    statusDot(statusKind(for: grant))
                    Text(label(for: grant))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            // "Open" only makes sense when there's still something for the
            // user to do — granted permissions don't need a deep-link.
            if grant != .granted {
                Button("Open") {
                    permission.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Open \(permission.displayName) settings")
                .accessibilityHint("Opens the System Settings pane where you can grant this permission.")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
        // Two distinct states with two distinct fixes — denial requires
        // System Settings, "not requested" will prompt on first use.
        case .denied:       return "Denied"
        case .notRequested: return "Not requested yet"
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
                        Text("Show indicator")
                            .font(.system(.callout, weight: .medium))
                        Text("A small Halen mark next to your cursor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: $showCaretIndicator)
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                        .accessibilityLabel("Show caret indicator")
                        .accessibilityHint("Draws a small Halen mark next to your text cursor while typing.")
                }

                // Style picker — only relevant when the indicator is on.
                if showCaretIndicator {
                    Divider().opacity(0.4)
                    HStack(spacing: 10) {
                        Text("Style")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $overlayDotStyle) {
                            Text("Solid").tag("solid")
                            Text("Outline").tag("outline")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Indicator style")
                        .accessibilityHint("Choose between a solid Halen dot or an outline-only version.")
                        Spacer()
                    }

                }
            }
        }
    }

    /// Apps and tone — short summary card plus a "Manage" button that
    /// opens the full per-app editor in a sheet. Used by Writing Coach
    /// (and previously Sentiment Guard / Clarity Checker) to adjust
    /// classification thresholds based on the focused app's formality.
    private var appTonesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("App tone profiles")
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toneProfilesSummary)
                            .font(.callout)
                        Text("Tell Halen which apps are formal (Mail, Outlook) and which are casual (Slack, iMessage). Writing rules adjust automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Manage…") {
                        presentingAppTonesEditor = true
                    }
                    .controlSize(.small)
                    .accessibilityHint("Opens the per-app tone profile editor.")
                }
            }
        }
    }

    private var toneProfilesSummary: String {
        let count = toneProfileStore.sortedEntries.count
        if count == 0 { return "No apps assigned yet." }
        if count == 1 { return "1 app has a tone assigned." }
        return "\(count) apps have a tone assigned."
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
                            .font(.caption2)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    // Icon-only button — both label and hint required so
                    // VoiceOver doesn't just say "Button."
                    .accessibilityLabel("Re-check backend availability")
                    .accessibilityHint("Re-probes every inference backend so the list reflects the current state.")
                }

                ForEach(Array(inferenceSettings.preferenceOrder.enumerated()), id: \.element) { index, kind in
                    backendRow(kind: kind, index: index)
                }

                Text("Tried in order. First available handles the request.")
                    .font(.caption)
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
                    .font(.caption)
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
                    .font(.caption)
                    .accessibilityHint("Opens the Apple Intelligence pane in System Settings so you can turn it on.")
                }
            }
            // Combine the dot + status text so VoiceOver hears the status
            // (e.g. "Apple Intelligence, Available") instead of "circle."
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            VStack(spacing: 2) {
                Button {
                    moveBackend(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityLabel("Move \(kind.displayName) up")
                .accessibilityHint("Tries this backend earlier when routing requests.")
                Button {
                    moveBackend(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .disabled(index == inferenceSettings.preferenceOrder.count - 1)
                .accessibilityLabel("Move \(kind.displayName) down")
                .accessibilityHint("Tries this backend later when routing requests.")
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
                        .font(.caption)
                        .fontWeight(.medium)
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
                            // Validate on every keystroke so the red outline
                            // and Save-disabled state track the draft in real
                            // time, not just on Save-click.
                            .onChange(of: ollamaURLDraft) { _, new in
                                ollamaURLInvalid = OllamaSettings.validate(new) == nil
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(ollamaURLInvalid ? Color.red : Color.clear,
                                            lineWidth: 1)
                            )
                            .accessibilityLabel("Ollama server URL")
                            .accessibilityHint("Network address of your local Ollama daemon. Default is http://localhost:11434.")
                        Button {
                            commitOllamaURL()
                        } label: {
                            Text("Save")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(ollamaURLInvalid || ollamaURLDraft == ollamaURLStored)
                        .accessibilityHint("Saves the new Ollama server URL and re-checks availability.")
                        Button {
                            ollamaURLStored = OllamaSettings.defaultBaseURLString
                            ollamaURLDraft = OllamaSettings.defaultBaseURLString
                            ollamaURLInvalid = false
                            Task { await router.refreshAvailability() }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reset to \(OllamaSettings.defaultBaseURLString)")
                        // Icon-only — VoiceOver needs an explicit label.
                        .accessibilityLabel("Reset Ollama URL")
                        .accessibilityHint("Restores the default Ollama address (\(OllamaSettings.defaultBaseURLString)).")
                    }
                }

                ollamaStatusLine

                Text("Ollama endpoint. Change only if you moved the daemon to a different port.")
                    .font(.caption)
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
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Not a valid http/https URL with a host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let url = OllamaSettings.validate(ollamaURLStored) {
            HStack(spacing: 6) {
                let loopback = OllamaSettings.isLoopback(url)
                statusDot(loopback ? .ok : .warning)
                Text(loopback
                     ? "Local. Requests stay on this Mac."
                     : "Remote. Requests leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Dot is decorative; the accompanying text is what users hear.
            .accessibilityElement(children: .combine)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Combine the dot + title + detail so VoiceOver reads
                    // "Ready, Gemma 4 E4B IQ4_XS…" instead of stumbling on
                    // the decorative circle.
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 6)
                    modelActionButton
                }

                if case let .downloading(fraction, bytes, total) = modelDownloader.state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel("Model download progress")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                    // .caption2 + monospacedDigit keeps the byte-counter
                    // tabular so digits don't dance as they change, while
                    // still scaling with Dynamic Type.
                    Text("\(formatBytes(bytes)) of \(formatBytes(total)) (\(Int(fraction * 100))%)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text("Runs on your Mac when Apple Intelligence is unavailable. Downloads on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Opt-in card for the dedicated compaction model (Qwen3-4B-Instruct-2507).
    /// Mirrors `builtInModelCard` but is never auto-downloaded — it powers the
    /// Reasoning Compactor's on-device Claude Code compaction. Until it's
    /// downloaded, compaction falls back to the built-in Gemma model.
    private var compactionModelCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Compaction model")

                HStack(spacing: 10) {
                    statusDot(compactionStatusKind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(compactionStatusTitle)
                            .font(.system(.callout, weight: .medium))
                        Text(compactionDownloader.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 6)
                    compactionActionButton
                }

                if case let .downloading(fraction, bytes, total) = compactionDownloader.state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel("Compaction model download progress")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                    Text("\(formatBytes(bytes)) of \(formatBytes(total)) (\(Int(fraction * 100))%)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text("Optional ~2.5 GB model that compacts Claude Code context on-device for the Reasoning Compactor. Until it's downloaded, compaction uses the built-in model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var compactionActionButton: some View {
        switch compactionDownloader.state {
        case .notDownloaded:
            Button("Download") { compactionDownloader.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Downloads the Qwen3 4B compaction model (about 2.5 gigabytes).")
        case .downloading:
            Button("Cancel") { compactionDownloader.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Stops the in-progress download.")
        case .verifying, .installing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Preparing compaction model")
        case .ready:
            Button("Remove") { confirmingCompactionRemove = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Deletes the locally stored compaction model. You can re-download it later.")
                .confirmationDialog("Delete the downloaded Qwen3 4B compaction model?",
                                    isPresented: $confirmingCompactionRemove,
                                    titleVisibility: .visible) {
                    Button("Delete (\(formatBytes(compactionDownloader.expectedSize)))",
                           role: .destructive) {
                        compactionDownloader.removeDownloaded()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Compaction will fall back to the built-in model until you re-download it. Takes effect on the next launch.")
                }
        case .failed:
            Button("Retry") { compactionDownloader.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Retries the failed compaction model download.")
        }
    }

    private var compactionStatusKind: StatusKind {
        switch compactionDownloader.state {
        case .ready:                                return .ok
        case .downloading, .verifying, .installing: return .warning
        case .notDownloaded:                        return .neutral
        case .failed:                               return .error
        }
    }

    private var compactionStatusTitle: String {
        switch compactionDownloader.state {
        case .notDownloaded: return "Not downloaded"
        case .downloading:   return "Downloading…"
        case .verifying:     return "Verifying…"
        case .installing:    return "Installing…"
        case .ready:         return "Ready"
        case .failed:        return "Download failed"
        }
    }

    @ViewBuilder
    private var modelActionButton: some View {
        switch modelDownloader.state {
        case .notDownloaded:
            Button("Download") { modelDownloader.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Downloads the bundled Gemma 4 E4B model (about 4.72 gigabytes).")
        case .downloading:
            Button("Cancel") { modelDownloader.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Stops the in-progress download.")
        case .verifying, .installing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Preparing model")
        case .ready:
            Button("Remove") { confirmingModelRemove = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Deletes the locally stored model. You can re-download it later.")
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
                .accessibilityHint("Retries the failed model download.")
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
            return "Installing…"
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
                            .accessibilityLabel("Browser bridge")
                            .accessibilityHint("Starts the local WebSocket so the Halen browser extension can connect.")
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
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    // Combine: dot is decorative, the surrounding text is
                    // what VoiceOver should read.
                    .accessibilityElement(children: .combine)
                    Text("Lets the browser extension report text from apps the system can't reach.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 2)

                    HStack(spacing: 8) {
                        Text("Pairing token")
                            .font(.caption)
                            .fontWeight(.medium)
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
                        .accessibilityLabel("Copy pairing token")
                        .accessibilityHint("Copies the bridge token to the clipboard so you can paste it into the browser extension.")
                        Button("Regenerate") { confirmingTokenRotate = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                            .accessibilityHint("Issues a new pairing token and disconnects every currently paired client.")
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
                                Text("Paired clients will need to enter the new token.")
                            }
                    }
                    Text("Browser extension: open its popup, paste this token, click Save.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func bridgeStatusDetail(_ bridge: WebSocketBridge) -> String {
        guard bridge.isListening else {
            return "Browser extension can't connect while off."
        }
        switch bridge.clientCount {
        case 0:  return "Listening — no clients connected."
        case 1:  return "1 client connected."
        default: return "\(bridge.clientCount) clients connected."
        }
    }

    /// Warning card listing every hotkey collision detected since launch.
    /// Hidden when there are none — most users never see it. Yellow accent
    /// so it reads as "needs attention" without screaming "broken"; the
    /// underlying chord is still owned by *one* plugin so nothing is
    /// silently lost.
    @ViewBuilder
    private var hotkeyConflictCard: some View {
        if !hotkeyConflicts.conflicts.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        cardLabel("Conflicting hotkeys")
                    }
                    ForEach(hotkeyConflicts.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(conflict.displayChord)
                                    .font(.system(.callout, design: .monospaced, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.orange.opacity(0.15))
                                    )
                                Text("held by")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(conflict.existingOwner)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("·")
                                    .foregroundStyle(.secondary)
                                Text(conflict.attemptedOwner)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .strikethrough()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(conflict.displayChord) held by \(conflict.existingOwner); \(conflict.attemptedOwner) was rejected")
                        }
                    }
                    Text("Disable one plugin or rebind its hotkey (rebinding coming in v0.4).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHint("Turn off one of the conflicting plugins in the marketplace to clear this warning.")
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
                    Text(versionDisplay)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        // VoiceOver should hear "version 0 point 2 point 0,
                        // build 2" not "v0.2.0 build 2" character-by-character.
                        .accessibilityLabel("Version \(appVersion), build \(buildNumber)")
                    Spacer()
                }
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/lukataylo/halen")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text("github.com/lukataylo/halen")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Halen on GitHub")
                .accessibilityHint("Opens github.com/lukataylo/halen in your browser.")

                Text("Local-first writing for macOS. Tone, clarity, and rewrites run on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Divider().opacity(0.4).padding(.vertical, 2)

                if updater.isActive {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                            Text("Check for updates")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .disabled(!updater.canCheckForUpdates)
                    .accessibilityHint("Asks Sparkle to check the appcast for a newer Halen release.")
                }

                Button {
                    onRunSetupAgain()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text("Re-run first-time setup")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Re-run first-time setup")
                .accessibilityHint("Walks you through permissions and plugin selection again.")

                Button {
                    NSWorkspace.shared.open(URL(string: "https://halen.dev/changelog.html")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.caption2)
                        Text("What's new")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("What's new")
                .accessibilityHint("Opens the Halen changelog in your browser.")
            }
        }
    }

    /// Resolved at runtime from CFBundleShortVersionString. Keeps the
    /// About card in sync with Info.plist without anyone hand-syncing the
    /// version string in two places. The fallback string is deliberately
    /// loud ("unknown") rather than "0.0.0" — a silent zero would hide the
    /// real failure mode (Info.plist not bundled, usually because the
    /// binary is being launched outside the .app wrapper).
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    /// Monotonic build number from CFBundleVersion. Shown alongside the
    /// semver string so two builds of the same release are tellable apart
    /// in bug reports.
    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    /// `v0.2.0 (2)` — the version line every bug report needs to lead with.
    private var versionDisplay: String { "v\(appVersion) (\(buildNumber))" }

    // MARK: - Helpers

    private enum StatusKind { case ok, warning, error, neutral }

    private func statusDot(_ kind: StatusKind) -> some View {
        // Saturation/luminance tuned so the dot clears WCAG AA contrast at
        // 50% material blend in light mode. The previous greens/ambers were
        // borderline against .regularMaterial; these darker values stay
        // legible without looking muddy in dark mode.
        let color: Color = {
            switch kind {
            case .ok:      return Color(red: 0.12, green: 0.55, blue: 0.22)
            case .warning: return Color(red: 0.78, green: 0.42, blue: 0.06)
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
        // The dot is decorative; the surrounding status text carries the
        // semantic meaning. Hiding it stops VoiceOver from announcing
        // "circle, circle" and lets the parent's `.accessibilityElement
        // (children: .combine)` surface the real status string.
        .accessibilityHidden(true)
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

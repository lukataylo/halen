import AppKit
import SwiftUI

/// Host-side presenter for the `ui/prompt` plugin capability — an interactive
/// popup with a body and a row of action buttons. Unlike `ui/toast` (fire and
/// forget), `ui/prompt` is a *request*: the plugin's RPC call suspends until
/// the user picks an action, and the chosen action string is the result.
///
/// One prompt at a time — a second `prompt(...)` dismisses any popup still on
/// screen (resolving its call as a dismiss) before showing the new one.
@MainActor
final class PluginPromptPresenter {
    private var panel: NSPanel?
    private var pending: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// Auto-dismiss after this long if the user neither picks nor closes it —
    /// so a plugin's `ui/prompt` call can't hang forever on an ignored popup.
    private static let timeout: Duration = .seconds(300)

    /// Show the prompt and suspend until the user picks an `action`, dismisses
    /// it, or it times out. Returns the chosen action string, or `nil` for
    /// dismiss / timeout.
    func prompt(title: String, body: String, actions: [String]) async -> String? {
        // Clear any prompt still up — its caller gets a dismiss result.
        dismiss(resolvingWith: nil)

        return await withCheckedContinuation { continuation in
            self.pending = continuation

            let size = NSSize(width: 360, height: 200)
            let panel = HalenFloatingPanel.make(
                size: size, level: .floating, interactive: true, shadow: true)
            panel.contentView = NSHostingView(rootView: PluginPromptView(
                title: title,
                message: body,
                actions: actions.isEmpty ? ["OK"] : actions,
                onChoose: { [weak self] choice in self?.dismiss(resolvingWith: choice) }
            ))
            // Bottom-right of the main screen — out of the way of the caret.
            if let screen = NSScreen.main {
                panel.setFrame(NSRect(
                    x: screen.visibleFrame.maxX - size.width - 20,
                    y: screen.visibleFrame.minY + 80,
                    width: size.width, height: size.height), display: true)
            }
            panel.orderFrontRegardless()
            self.panel = panel
            Log.info("ui/prompt shown: \(title) — \(actions.count) action(s)")

            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard !Task.isCancelled else { return }
                self?.dismiss(resolvingWith: nil)
            }
        }
    }

    /// Tear down the popup and resolve the pending call exactly once.
    private func dismiss(resolvingWith choice: String?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        panel?.orderOut(nil)
        panel = nil
        if let continuation = pending {
            pending = nil
            Log.info("ui/prompt resolved: \(choice ?? "(dismissed)")")
            continuation.resume(returning: choice)
        }
    }
}

/// Generic prompt popup: a body line and one button per action. The first
/// action is rendered as the prominent (primary) button — plugins put the
/// affirmative action first.
@MainActor
private struct PluginPromptView: View {
    let title: String
    let message: String
    let actions: [String]
    let onChoose: (String?) -> Void

    /// Targets for focus-on-appear. We always have at least one action button
    /// (`PluginPromptPresenter` injects "OK" when the plugin sends an empty
    /// action list), so the primary case is reachable in every prompt.
    private enum Field: Hashable { case primary, close }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.halenCobalt)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button { onChoose(nil) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focused($focusedField, equals: .close)
                .accessibilityLabel("Dismiss prompt")
                .accessibilityHint("Close this prompt without choosing an action.")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Text(message)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Spacer()
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    // First action is the affirmative one — plugins order
                    // it first; render it prominent, the rest plain.
                    if index == 0 {
                        Button(action) { onChoose(action) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .focused($focusedField, equals: .primary)
                            .accessibilityHint("Primary action for this prompt.")
                    } else {
                        Button(action) { onChoose(action) }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Focus the primary action on appear — VoiceOver and keyboard-only
        // users otherwise land on the host panel itself, with no obvious way
        // to know which buttons are available. Short hop matches the pattern
        // we use in the other floating popovers.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focusedField = .primary
        }
    }
}

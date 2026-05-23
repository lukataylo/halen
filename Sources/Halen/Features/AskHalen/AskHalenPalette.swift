import SwiftUI

/// SwiftUI floating palette: text field on top, response below, action row at
/// the bottom. The whole panel is hosted in an `NSPanel` by `AskHalen`.
///
/// **Why `@ObservedObject` not `@Bindable`:** the @Observable+@Bindable chain
/// silently failed to re-render `Text(state.response)` inside the panel's
/// `NSHostingView`, even though logs proved the model returned a 39-char
/// response. The classic `@Published`+`@ObservedObject` chain is older but
/// rock-solid in NSHostingView contexts. See `AskHalenState` doc for detail.
///
/// **Why the output area always renders:** previously the output area was
/// mounted conditionally (`if hasOutput { … }`). Conditional mounting +
/// observation can produce a state where the parent re-renders but the newly
/// mounted child doesn't pick up the latest values for a tick. We avoid the
/// whole class of bug by always rendering the output area and switching its
/// *content* based on state — every body evaluation reads every relevant
/// field, so observation tracking is guaranteed.
@MainActor
struct AskHalenPalette: View {
    @ObservedObject var state: AskHalenState
    let onSubmit: () -> Void
    let onCopy: () -> Void
    let onInsert: () -> Void
    let onClose: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        // Local lets up front so SwiftUI's observation tracking always sees
        // these reads on every body evaluation, regardless of which branch
        // the view ends up rendering. Defensive — `@Published` should track
        // already, but this makes the contract explicit and grep-able.
        let isStreaming = state.isStreaming
        let response = state.response
        let errorMessage = state.errorMessage
        let hasSubmitted = state.hasSubmitted

        VStack(spacing: 0) {
            inputRow
            Divider().opacity(0.4)
            outputArea(
                isStreaming: isStreaming,
                response: response,
                errorMessage: errorMessage,
                hasSubmitted: hasSubmitted
            )
            Divider().opacity(0.4)
            actionRow(response: response)
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
        // Focus the input *after* the panel has had time to become key.
        // `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` is
        // async, so a synchronous `inputFocused = true` in `.onAppear` would
        // be silently dropped if the window isn't key yet. The short hop on
        // the main actor gives the AppKit transition time to settle.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            inputFocused = true
        }
        // Esc anywhere closes the palette.
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private var insertButtonLabel: String {
        state.context.focusedElement == nil ? "Copy" : "Insert"
    }

    private var insertButtonIcon: String {
        state.context.focusedElement == nil ? "doc.on.doc" : "arrow.down.to.line"
    }

    // MARK: - Sections

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.halenCobalt)
            TextField("Ask Halen…", text: $state.question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($inputFocused)
                .lineLimit(1...4)
                .onSubmit(onSubmit)

            if state.isStreaming {
                ProgressView().controlSize(.small)
            } else {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(state.question.isEmpty ? .secondary : Color.halenCobalt)
                }
                .buttonStyle(.plain)
                .disabled(state.question.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }

            // Always-visible click escape. Esc is the primary path, but if
            // anything ever breaks the keyboard handler the user still has
            // a way out without having to kill the app.
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (⎋)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// One always-mounted block that flips its content based on state.
    /// Selectable text, scrollable when long. Min height keeps the layout
    /// stable so the palette doesn't visibly jump as states change.
    private func outputArea(
        isStreaming: Bool,
        response: String,
        errorMessage: String?,
        hasSubmitted: Bool
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isStreaming && response.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if !response.isEmpty {
                    // `Text(verbatim:)` to ensure no markdown / format string
                    // interpretation eats unusual content.
                    Text(verbatim: response)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if hasSubmitted && !isStreaming {
                    Text("No response. Try rephrasing.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    contextHintBody
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(minHeight: 64, maxHeight: 280)
    }

    private func actionRow(response: String) -> some View {
        HStack(spacing: 8) {
            contextChip
            Spacer()
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(response.isEmpty)

            Button(action: onInsert) {
                Label(insertButtonLabel, systemImage: insertButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(response.isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(state.context.focusedElement == nil
                  ? "No text field focused — ⌘⏎ copies to clipboard."
                  : "Insert at your caret.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Tiny "you're working in Slack, X selected" chip in the action row.
    private var contextChip: some View {
        Group {
            if let chip = contextSummary {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.dashed.badge.record")
                        .font(.system(size: 9))
                    Text(chip)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(.thinMaterial)
                        .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
                )
            }
        }
    }

    private var contextSummary: String? {
        var parts: [String] = []
        if let app = state.context.appName { parts.append("in \(app)") }
        if let sel = state.context.selectedText, !sel.isEmpty {
            parts.append("\(sel.count) char selection")
        } else if let para = state.context.currentParagraph, !para.isEmpty {
            parts.append("paragraph around caret")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Pre-submit hint, rendered inside the always-mounted output area.
    private var contextHintBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chip = contextSummary {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.system(size: 10))
                    Text(chip)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            } else {
                Text("Halen will answer based on your question.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Return to send · Esc to close")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

/// SwiftUI floating palette: text field on top, response below, action row at
/// the bottom. The whole panel is hosted in an `NSPanel` by `AskHalen`, so
/// SwiftUI-side just needs to read `state` and call the action closures.
struct AskHalenPalette: View {
    @Bindable var state: AskHalenState
    let onSubmit: () -> Void
    let onCopy: () -> Void
    let onInsert: () -> Void
    let onClose: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if hasOutput {
                Divider().opacity(0.4)
                outputArea
                Divider().opacity(0.4)
                actionRow
            } else {
                contextHint
            }
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
        .onAppear { inputFocused = true }
        // Esc anywhere closes the palette.
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private var hasOutput: Bool {
        state.isStreaming || !state.response.isEmpty || state.errorMessage != nil
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
            // anything ever breaks the keyboard handler (focus race, future
            // overlay panel hijack) the user still has a way out without
            // having to kill the app from Activity Monitor.
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // also binds ⎋ at button level
            .help("Close (⎋)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var outputArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let error = state.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(state.response.isEmpty ? " " : state.response)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 280)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            contextChip
            Spacer()
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.response.isEmpty)

            Button(action: onInsert) {
                // Switches labels when there's no AX target so the user
                // understands the keyboard shortcut still does *something*
                // (copy-and-close) rather than appearing inert.
                Label(insertButtonLabel, systemImage: insertButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state.response.isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(state.context.focusedElement == nil
                  ? "No text field focused — ⌘⏎ copies to clipboard."
                  : "Insert at your caret.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Tiny "you're working in Slack, X selected" chip. Tells the user what
    /// context Halen captured without making them guess.
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

    /// What you see BEFORE submitting — a hint at the rich context Halen
    /// already has, so the user doesn't have to over-explain in the question.
    private var contextHint: some View {
        VStack(spacing: 8) {
            if let chip = contextSummary {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.system(size: 10))
                    Text(chip)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            } else {
                Text("No context detected — Halen will answer with what you type.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("⏎ to send · ⎋ to close")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

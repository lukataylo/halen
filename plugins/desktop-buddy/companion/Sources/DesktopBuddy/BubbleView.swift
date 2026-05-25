import SwiftUI

/// Bubble state. Driven by `AppDelegate` in response to bridge messages.
final class BubbleModel: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case say(String, isError: Bool)
        case input(InputMode)
    }

    @Published var mode: Mode = .hidden
    @Published var draft: String = ""
    @Published var focusInput: Bool = false
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    let onSubmit: (String) -> Void
    let onClose: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            switch model.mode {
            case .hidden:
                Color.clear.frame(width: 1, height: 1)
            case .say(let text, let isError):
                sayBody(text: text, isError: isError)
            case .input(let mode):
                inputBody(mode: mode)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
        )
        .padding(6) // keep the shadow inside the window's content area
        .onChange(of: model.focusInput) { _, newValue in
            if newValue { inputFocused = true }
        }
    }

    private func sayBody(text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "sparkles")
                .foregroundStyle(isError ? Color.orange : Color.accentColor)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputBody(mode: InputMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: mode == .rewrite ? "pencil.and.outline" : "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Color.accentColor)
                Text(mode.heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }

            TextField(mode.placeholder, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($inputFocused)

            HStack {
                Text(mode == .rewrite
                     ? "Halen will rewrite the selected text in place."
                     : "Press ⌘⏎ to send.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Send", action: submit)
                    // ⌘⏎ rather than plain Return so a multi-line TextField
                    // can still insert newlines while the field has focus.
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        let trimmed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        model.draft = ""
    }
}

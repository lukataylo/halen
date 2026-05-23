import SwiftUI

@MainActor
struct SnippetExpanderDetailView: View {
    @Bindable var store: SnippetStore

    @State private var showAdd = false
    @State private var newTrigger = ""
    @State private var newName = ""
    @State private var newKind: Snippet.Kind = .staticText
    @State private var newValue = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                triggersCard
                howItWorksCard
            }
            .padding(12)
        }
    }

    // MARK: - Triggers

    private var triggersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardLabel("Snippets")
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.2)) { showAdd.toggle() }
                    } label: {
                        Image(systemName: showAdd ? "minus.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                if showAdd {
                    addForm
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(spacing: 0) {
                    ForEach(store.sorted) { snippet in
                        SnippetRow(
                            snippet: snippet,
                            onDelete: { store.remove(snippet.trigger) },
                            onSave:   { updated in
                                // `update` upserts — and converts a builtin
                                // into a custom override that survives the
                                // ensureBuiltins reset on next launch.
                                store.update(
                                    trigger:     updated.trigger,
                                    kind:        updated.kind,
                                    value:       updated.value,
                                    displayName: updated.displayName
                                )
                            }
                        )
                        if snippet.id != store.sorted.last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(";trigger", text: $newTrigger)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 110)

                TextField("Display name", text: $newName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                    .font(.system(size: 12))
            }

            Picker("", selection: $newKind) {
                Text("Static text").tag(Snippet.Kind.staticText)
                Text("AI (Gemma prompt)").tag(Snippet.Kind.ai)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(
                newKind == .staticText ? "Literal text to insert…" : "Prompt for Gemma (prior text is appended)…",
                text: $newValue,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
            .font(.system(size: 12))
            .lineLimit(2...5)

            HStack {
                Spacer()
                Button {
                    store.addCustom(trigger: newTrigger, kind: newKind, value: newValue, displayName: newName)
                    newTrigger = ""
                    newName = ""
                    newValue = ""
                    newKind = .staticText
                    withAnimation(.spring(duration: 0.2)) { showAdd = false }
                } label: {
                    Label("Add snippet", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                          || newName.trimmingCharacters(in: .whitespaces).isEmpty
                          || newValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    // MARK: - How it works

    private var howItWorksCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("How it works")
                Text("Type the trigger like ;sig or ;today followed by a space or punctuation. Halen swaps it for the snippet's content.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("AI snippets get the previous ~500 characters as context. A `[…]` placeholder shows while Gemma generates, then swaps to the result.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.4).padding(.vertical, 2)
                Text("Rephrase a selection: highlight any text in any app and press ⌃⌥R. Halen rewrites just that selection in place — handy when you don't want to rephrase the whole paragraph.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

// MARK: - Row

/// Row with inline edit-on-double-click. Builtins can be edited too — the
/// store converts the edit into a custom override that survives the launch-time
/// `ensureBuiltins` refresh, and Reset restores the original prompt.
@MainActor
private struct SnippetRow: View {
    let snippet: Snippet
    let onDelete: () -> Void
    /// Called with the user's edited copy when they hit Save / press Enter.
    let onSave: (Snippet) -> Void

    @State private var hovering = false
    @State private var isEditing = false

    // Edit-mode drafts. Initialised from the snippet whenever editing begins.
    @State private var draftValue = ""
    @State private var draftName = ""
    @State private var draftKind: Snippet.Kind = .staticText
    @FocusState private var editorFocused: Bool

    var body: some View {
        if isEditing {
            editor
        } else {
            displayRow
        }
    }

    // MARK: - Display

    private var displayRow: some View {
        HStack(spacing: 10) {
            kindBadge

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(snippet.trigger)
                        .font(.system(.callout, design: .monospaced, weight: .medium))
                    if snippet.builtin {
                        Text("BUILT-IN")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                    }
                }
                Text(snippet.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(preview)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Pencil edit button — visible on hover. Double-click anywhere on
            // the row also enters edit mode (handled by the .onTapGesture).
            if hovering {
                Button(action: beginEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit snippet (or double-click row)")
            }

            if !snippet.builtin {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.7)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { beginEdit() }
        .help("Double-click to edit.")
    }

    // MARK: - Edit

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                kindBadge
                Text(snippet.trigger)
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                if snippet.builtin {
                    Text("BUILT-IN · editing creates an override")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                }
                Spacer()
            }

            TextField("Display name", text: $draftName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.system(size: 12))

            // Dynamic builtins (`;today`, `;time`) don't expose a useful
            // value to edit — the value is a sentinel string consumed by the
            // expander, not template text. Hide the kind picker and value
            // field for that case to avoid confusing the user.
            if snippet.kind != .dynamic {
                Picker("", selection: $draftKind) {
                    Text("Static text").tag(Snippet.Kind.staticText)
                    Text("AI (Gemma prompt)").tag(Snippet.Kind.ai)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField(
                    draftKind == .staticText
                        ? "Literal text to insert…"
                        : "Prompt for Gemma (prior text is appended)…",
                    text: $draftValue,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.system(size: 12))
                .lineLimit(2...6)
                .focused($editorFocused)
                .onSubmit(commit)
            } else {
                Text("This is a built-in dynamic snippet — only the display name is editable.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Cancel", action: cancelEdit)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Spacer()
                Button(action: commit) {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("⌘⏎ save · ⎋ cancel")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
        .padding(.vertical, 4)
        .onExitCommand(perform: cancelEdit)
    }

    // MARK: - Actions

    private func beginEdit() {
        draftValue = snippet.value
        draftName = snippet.displayName
        draftKind = snippet.kind == .dynamic ? .staticText : snippet.kind
        isEditing = true
        // Focus the value field after the editor mounts. Dynamic snippets
        // don't render a value field; focus is harmless if no field claims it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            editorFocused = true
        }
    }

    private func commit() {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        // For dynamic builtins, keep the original value/kind — only the
        // display name can change. For everything else we send the drafts.
        let kind = snippet.kind == .dynamic ? snippet.kind : draftKind
        let value = snippet.kind == .dynamic ? snippet.value : draftValue
        onSave(
            Snippet(
                trigger: snippet.trigger,
                kind: kind,
                value: value,
                displayName: trimmedName,
                builtin: false,
                replacesPrior: snippet.replacesPrior
            )
        )
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
        draftValue = ""
        draftName = ""
    }

    private var preview: String {
        switch snippet.kind {
        case .dynamic: return "Inserts the current \(snippet.value)"
        default:
            let trimmed = snippet.value.prefix(60)
            return snippet.value.count > 60 ? "\(trimmed)…" : String(trimmed)
        }
    }

    private var kindBadge: some View {
        let (color, symbol): (Color, String) = {
            switch snippet.kind {
            case .staticText: return (Color.blue, "doc.text")
            case .dynamic:    return (Color.orange, "clock")
            case .ai:         return (Color.purple, "sparkles")
            }
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 26, height: 26)
    }
}

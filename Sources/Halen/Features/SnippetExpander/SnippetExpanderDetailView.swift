import SwiftUI

@MainActor
struct SnippetExpanderDetailView: View {
    @Bindable var store: SnippetStore

    @State private var showAdd = false
    @State private var newTrigger = ""
    @State private var newName = ""
    @State private var newKind: Snippet.Kind = .staticText
    @State private var newValue = ""

    /// Sane bounds for a custom trigger. Two chars enforces "more than just
    /// the leading `;`"; twenty caps the keystroke savings vs typing it out
    /// at the point the trigger stops being a *shortcut*.
    private static let triggerMinLength = 2
    private static let triggerMaxLength = 20
    /// Practical upper bound on snippet payload. AI snippets with multi-KB
    /// prompts slow expansion to seconds and overflow the model's context;
    /// static snippets that long are usually a paste accident.
    private static let valueMaxLength = 4_000

    /// User-facing warning for an obviously-broken trigger, or `nil` when
    /// the field is empty or valid. Shown inline above the Add button.
    private var triggerValidationMessage: String? {
        let trimmed = newTrigger.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count < Self.triggerMinLength {
            return "Triggers need at least \(Self.triggerMinLength) characters."
        }
        if trimmed.count > Self.triggerMaxLength {
            return "Triggers should be under \(Self.triggerMaxLength) characters."
        }
        if store.sorted.contains(where: { $0.trigger.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "That trigger already exists."
        }
        return nil
    }

    /// Composite gate the Add button reads. Empty fields, validation
    /// errors, or oversized values all block submission.
    private var isFormValid: Bool {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        let name = newName.trimmingCharacters(in: .whitespaces)
        let value = newValue.trimmingCharacters(in: .whitespaces)
        return triggerValidationMessage == nil
            && !trigger.isEmpty
            && !name.isEmpty
            && !value.isEmpty
            && value.count <= Self.valueMaxLength
    }

    /// Two-column field-row helper. Keeps the labels aligned in a tight
    /// 52pt gutter so the input columns line up across rows without each
    /// caller restating padding.
    @ViewBuilder private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Semantic .caption — Larger Accessibility Sizes scales the field label.
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 6)
            content()
        }
    }

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
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(showAdd ? "Cancel new snippet" : "Add a new snippet")
                    .accessibilityHint(showAdd
                                       ? "Closes the add-snippet form."
                                       : "Opens a form to add a new snippet.")
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
        // Field-per-row layout. The prior version crammed trigger +
        // display-name into a single HStack which looked cramped at the
        // dropdown's 380 pt width — and tucked "Add snippet" inside a
        // sub-rect that fought for visual hierarchy with the kind picker.
        // Each input gets its own row with a small monochrome label;
        // primary action sits at the bottom-right of the card with a
        // matched Cancel.
        VStack(alignment: .leading, spacing: 10) {
            fieldRow(label: "Trigger") {
                TextField(";short", text: $newTrigger)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityLabel("Trigger")
                    .accessibilityHint("Short string Halen will match and replace.")
            }

            fieldRow(label: "Name") {
                TextField("What to call it", text: $newName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                    .font(.callout)
                    .accessibilityLabel("Snippet name")
                    .accessibilityHint("Display name shown in the snippets list.")
            }

            fieldRow(label: "Type") {
                Picker("", selection: $newKind) {
                    Text("Static text").tag(Snippet.Kind.staticText)
                    Text("AI prompt").tag(Snippet.Kind.ai)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Snippet type")
                .accessibilityHint("Static text inserts literally; AI prompt asks the model to generate text.")
            }

            fieldRow(label: newKind == .staticText ? "Text" : "Prompt") {
                TextField(
                    newKind == .staticText
                        ? "Literal text to insert…"
                        : "Prompt for the model. Prior text is appended.",
                    text: $newValue,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.callout)
                .lineLimit(3...6)
                .accessibilityLabel(newKind == .staticText ? "Snippet text" : "AI prompt")
                .accessibilityHint(newKind == .staticText
                                   ? "Text that gets inserted when the trigger fires."
                                   : "Prompt the model uses to generate the replacement.")
            }

            // Validation hint when the trigger is suspiciously short/long
            // or duplicates an existing one. Inline so the user can fix
            // before reaching for the Add button.
            if let warning = triggerValidationMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 60)   // align with field column
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    newTrigger = ""
                    newName = ""
                    newValue = ""
                    newKind = .staticText
                    withAnimation(.spring(duration: 0.2)) { showAdd = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Discards what you typed and closes the form.")

                Button {
                    store.addCustom(trigger: newTrigger, kind: newKind, value: newValue, displayName: newName)
                    newTrigger = ""
                    newName = ""
                    newValue = ""
                    newKind = .staticText
                    withAnimation(.spring(duration: 0.2)) { showAdd = false }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isFormValid)
                .accessibilityHint("Saves the new snippet and closes the form.")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("AI snippets use nearby text as context. A placeholder shows while generating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.4).padding(.vertical, 2)
                Text("Highlight text and press ⌃⌥R to rewrite just the selection.")
                    .font(.caption)
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
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                    }
                }
                Text(snippet.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Pencil edit button — visible on hover. Double-click anywhere on
            // the row also enters edit mode (handled by the .onTapGesture).
            if hovering {
                Button(action: beginEdit) {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit snippet (or double-click row)")
                .accessibilityLabel("Edit snippet \(snippet.trigger)")
                .accessibilityHint("Opens the inline editor for this snippet.")
            }

            if !snippet.builtin {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.7)
                .accessibilityLabel("Delete snippet \(snippet.trigger)")
                .accessibilityHint("Removes this custom snippet.")
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
                    Text("BUILT-IN · edits create a custom copy")
                        .font(.caption2)
                        .fontWeight(.semibold)
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
                .font(.callout)
                .accessibilityLabel("Display name")
                .accessibilityHint("Name shown in the snippets list.")

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
                .accessibilityLabel("Snippet type")

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
                .font(.callout)
                .lineLimit(2...6)
                .focused($editorFocused)
                .onSubmit(commit)
                .accessibilityLabel(draftKind == .staticText ? "Snippet text" : "AI prompt")
            } else {
                Text("Built-in dynamic snippet. Only the name is editable.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Cancel", action: cancelEdit)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityHint("Discards your edits and closes the editor.")
                Spacer()
                Button(action: commit) {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityHint("Saves your edits to this snippet.")
            }
            Text("⌘⏎ save · ⎋ cancel")
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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
        let kindLabel: String = {
            switch snippet.kind {
            case .staticText: return "Static text snippet"
            case .dynamic:    return "Dynamic snippet"
            case .ai:         return "AI snippet"
            }
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.18))
            Image(systemName: symbol)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(kindLabel)
    }
}

import SwiftUI

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
                        SnippetRow(snippet: snippet, onDelete: { store.remove(snippet.trigger) })
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
            }
        }
    }

}

// MARK: - Row

private struct SnippetRow: View {
    let snippet: Snippet
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
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
                if !snippet.builtin {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

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
    }

    private var preview: String {
        let trimmed = snippet.value.prefix(60)
        return snippet.value.count > 60 ? "\(trimmed)…" : String(trimmed)
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

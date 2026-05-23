import SwiftUI

@MainActor
struct AutocompleteDetailView: View {
    /// Extra debounce on top of text.pause before a suggestion fires.
    /// 0…500 ms; 0 keeps the historical immediate-suggest behaviour.
    @AppStorage(Autocomplete.extraSettleKey) private var extraSettleMs: Int = 0
    /// Comma-separated app bundle id whitelist. Empty = suggest everywhere.
    @AppStorage(Autocomplete.whitelistKey) private var whitelistCSV: String = ""
    /// Local field for adding a new bundle id.
    @State private var newWhitelistApp: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                howCard
                latencyCard
                whitelistCard
                limitsCard
            }
            .padding(12)
        }
    }

    private var howCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("How it works")
                HStack(spacing: 8) {
                    Image(systemName: "text.append")
                        .foregroundStyle(Color.accentColor)
                    Text("Pause while typing")
                        .font(.system(.callout, weight: .medium))
                }
                Text("Pause typing to see suggestions in gray. Press Tab to accept.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var latencyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    cardLabel("Suggestion delay")
                    Spacer()
                    Text(extraSettleMs == 0 ? "Off" : "\(extraSettleMs) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(extraSettleMs) },
                        set: { extraSettleMs = Int($0.rounded()) }
                    ),
                    in: 0...500, step: 25
                )
                Text("Extra delay after you stop typing before a suggestion appears. 0 ms keeps the default immediate behaviour; higher values feel less eager.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whitelist: [String] {
        whitelistCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var whitelistCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("App whitelist")
                Text("Leave empty to suggest in every app. Add bundle ids (e.g. com.apple.TextEdit) to restrict suggestions to just those apps.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    TextField("com.apple.TextEdit", text: $newWhitelistApp)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                    Button {
                        addWhitelistApp()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(newWhitelistApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(newWhitelistApp.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.secondary.opacity(0.4) : Color.accentColor)
                }

                if whitelist.isEmpty {
                    Text("Suggesting in every app.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(whitelist, id: \.self) { bundleId in
                            HStack {
                                Text(bundleId)
                                    .font(.system(.callout, design: .monospaced))
                                Spacer()
                                Button {
                                    removeWhitelistApp(bundleId)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func addWhitelistApp() {
        let trimmed = newWhitelistApp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var current = whitelist
        guard !current.contains(trimmed) else { newWhitelistApp = ""; return }
        current.append(trimmed)
        whitelistCSV = current.joined(separator: ",")
        newWhitelistApp = ""
    }

    private func removeWhitelistApp(_ bundleId: String) {
        var current = whitelist
        current.removeAll { $0 == bundleId }
        whitelistCSV = current.joined(separator: ",")
    }

    private var limitsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Known limits")
                Text("Suggestions appear as a floating overlay. Alignment is best in Mail, Notes, and TextEdit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI

/// Settings + reference for Prompt Polish. The plugin itself is hotkey-driven
/// (⌃⌥P); this view picks which transform the hotkey applies and, for tone
/// mode, which register to steer toward. The reference card explains what each
/// mode changes at the word level.
@MainActor
struct PromptPolishDetailView: View {
    @AppStorage(PromptPolish.defaultModeKey) private var modeRaw: String =
        PromptPolish.PolishMode.improve.rawValue
    @AppStorage(PromptPolish.toneTargetKey) private var toneRaw: String =
        PromptPolish.ToneTarget.professional.rawValue

    private var mode: PromptPolish.PolishMode {
        PromptPolish.PolishMode(rawValue: modeRaw) ?? .improve
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                modeCard
                if mode == .tone { toneCard }
                howItWorksCard
                whatItChangesCard
            }
            .padding(12)
        }
    }

    // MARK: - Mode

    private var modeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("What ⌃⌥P does")
                Text("Pick the transform Halen applies when you select a prompt and press ⌃⌥P.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $modeRaw) {
                    ForEach(PromptPolish.PolishMode.allCases, id: \.rawValue) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Default polish mode")
                .accessibilityHint("Picks the transform the ⌃⌥P hotkey applies to the selected prompt.")
                Label {
                    Text(mode.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: mode.systemImage)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Tone target

    private var toneCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Target register")
                Text("Which voice the answer should adopt. Halen sets it mostly through word choice — the register-lab study found these are the registers a single word can reliably steer toward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $toneRaw) {
                    ForEach(PromptPolish.ToneTarget.allCases, id: \.rawValue) { t in
                        Text(t.label).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Target tone register")
            }
        }
    }

    // MARK: - How it works

    private var howItWorksCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("How it works")
                Text("Highlight the prompt you're about to send to an AI — in any app, including a ChatGPT, Claude, or Gemini text box — and press ⌃⌥P. Halen rewrites it in place with word-level edits. A placeholder shows while it works; press ⌘Z to undo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Everything runs on-device. Your prompt never leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Reference

    private var whatItChangesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("What each mode changes")
                ForEach(PromptPolish.PolishMode.allCases, id: \.rawValue) { m in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: m.systemImage)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.label)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(m.blurb)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if m != PromptPolish.PolishMode.allCases.last {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
}

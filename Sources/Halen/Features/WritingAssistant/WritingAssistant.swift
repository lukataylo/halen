import SwiftUI

/// The single "Grammarly-esque" writing surface — the user-facing rollup of the
/// three engines that assist text *as you write it*:
///
///   1. **Corrections** (`WordReplacements`) — silent inline typo fixes plus
///      user-defined banned → preferred term swaps.
///   2. **Clarity & tone** (`WritingCoach`) — flags weak/over-strong tone and
///      unclear sentences with a findings popover.
///   3. **Autocomplete** — ghost-text completion of the next few words (Tab to
///      accept).
///
/// These were three separate plugins. They are the same job — ambient
/// assistance on text you're writing — so they're surfaced as one plugin with a
/// single on/off switch. Halen's focus has shifted to model orchestration;
/// "writing help" is now one consolidated feature rather than a cluster of
/// independent toggles. The three engines stay as distinct internal objects so
/// their honest, different UX models (silent inline / popover / ghost-text)
/// survive the merge; the wrapper just starts/stops them together and hosts a
/// tabbed detail view.
///
/// Default-ON. Autocomplete used to be opt-in (its ghost-text is interrupting),
/// but with a single switch it rides along with the default-on corrections and
/// clarity engines.
///
/// Migration: previous installations toggled `com.halen.word-replacements`,
/// `com.halen.writing-coach`, and `com.halen.autocomplete` independently.
/// `PluginRegistry` migrates this id's enabled-state from any of those three on
/// first launch — see `PluginRegistry.readPersistedEnabled`.
@MainActor
final class WritingAssistant: HalenPlugin {
    let id = "com.halen.writing-assistant"
    let name = "Writing Assistant"
    let summary = "Fixes typos, flags tone & clarity, finishes your sentences."
    let icon = "pencil.line"
    let category: PluginCategory = .writing

    /// Silent inline typo fixes + preferred-term swaps.
    let wordReplacements: WordReplacements
    /// Tone + clarity findings as you write.
    let writingCoach: WritingCoach
    /// Ghost-text next-word completion (Tab to accept).
    let autocomplete: Autocomplete

    init(services: HalenServices, typoStore: TypoStore) {
        self.wordReplacements = WordReplacements(services: services, typoStore: typoStore)
        self.writingCoach = WritingCoach(services: services)
        self.autocomplete = Autocomplete(services: services)
    }

    func start() {
        wordReplacements.start()
        writingCoach.start()
        autocomplete.start()
    }

    func stop() {
        wordReplacements.stop()
        writingCoach.stop()
        autocomplete.stop()
    }

    func makeDetailView() -> AnyView {
        AnyView(
            WritingAssistantDetailView(
                corrections: wordReplacements.makeDetailView(),
                clarity: writingCoach.makeDetailView(),
                autocomplete: autocomplete.makeDetailView()
            )
        )
    }
}

/// Tabs across the three engines' own settings panels. One plugin, one switch,
/// but each engine's distinct configuration (custom replacements, tone targets,
/// autocomplete options) stays reachable behind its tab.
@MainActor
private struct WritingAssistantDetailView: View {
    let corrections: AnyView
    let clarity: AnyView
    let autocomplete: AnyView

    @State private var tab: Section = .corrections

    private enum Section: String, CaseIterable, Identifiable {
        case corrections = "Corrections"
        case clarity = "Clarity & Tone"
        case autocomplete = "Autocomplete"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Writing Assistant section", selection: $tab) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .accessibilityLabel("Writing Assistant settings section")

            Divider().opacity(0.4)

            switch tab {
            case .corrections:  corrections
            case .clarity:      clarity
            case .autocomplete: autocomplete
            }
        }
    }
}

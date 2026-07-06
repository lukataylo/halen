import SwiftUI

/// The single "Grammarly-esque" writing surface — the user-facing rollup of the
/// engines that assist text *as you write it*:
///
///   1. **Corrections** (`WordReplacements`) — silent inline typo fixes plus
///      user-defined banned → preferred term swaps.
///   2. **Clarity & tone** (`WritingCoach`) — flags weak/over-strong tone and
///      unclear sentences with a findings popover.
///
/// These were separate plugins. They are the same job — ambient assistance on
/// text you're writing — so they're surfaced as one plugin with a single on/off
/// switch. Halen's focus has shifted to model orchestration; "writing help" is
/// now one consolidated feature rather than a cluster of independent toggles.
/// The engines stay as distinct internal objects so their honest, different UX
/// models (silent inline / popover) survive the merge; the wrapper just
/// starts/stops them together and hosts a tabbed detail view.
///
/// Migration: previous installations toggled `com.halen.word-replacements` and
/// `com.halen.writing-coach` independently. `PluginRegistry` migrates this id's
/// enabled-state from those on first launch — see
/// `PluginRegistry.readPersistedEnabled`.
@MainActor
final class WritingAssistant: HalenPlugin {
    let id = "com.halen.writing-assistant"
    let name = "Writing Assistant"
    let summary = "Fixes typos, flags tone & clarity as you write."
    let icon = "pencil.line"
    let category: PluginCategory = .writing

    /// Silent inline typo fixes + preferred-term swaps.
    let wordReplacements: WordReplacements
    /// Tone + clarity findings as you write.
    let writingCoach: WritingCoach

    init(services: HalenServices, typoStore: TypoStore) {
        self.wordReplacements = WordReplacements(services: services, typoStore: typoStore)
        self.writingCoach = WritingCoach(services: services)
    }

    func start() {
        wordReplacements.start()
        writingCoach.start()
    }

    func stop() {
        wordReplacements.stop()
        writingCoach.stop()
    }

    func makeDetailView() -> AnyView {
        AnyView(
            WritingAssistantDetailView(
                corrections: wordReplacements.makeDetailView(),
                tone: writingCoach.sentimentGuard.makeDetailView(),
                clarity: writingCoach.clarityChecker.makeDetailView()
            )
        )
    }
}

/// Tabs across the engines' own settings panels. One plugin, one switch, but
/// each engine's distinct configuration (custom replacements, tone targets)
/// stays reachable behind its tab.
@MainActor
private struct WritingAssistantDetailView: View {
    let corrections: AnyView
    let tone: AnyView
    let clarity: AnyView

    @State private var tab: Section = .corrections

    private enum Section: String, CaseIterable, Identifiable {
        case corrections = "Corrections"
        case tone = "Tone"
        case clarity = "Clarity"
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
            case .tone:         tone
            case .clarity:      clarity
            }
        }
    }
}

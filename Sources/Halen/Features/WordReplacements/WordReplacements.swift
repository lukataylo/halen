import SwiftUI

/// Word-level replacement engine — the user-facing rollup of two distinct
/// internal engines that both turn one string into another:
///
///   1. **Auto typo fixer** — learns from the user's own corrections,
///      replaces silently inline when it sees a known typo + word boundary.
///      High-confidence path; no UI surface.
///   2. **Personal preferences** — user-defined banned-term / preferred-term
///      rules, applied at the paragraph level with a popover that asks
///      "replace?". Lower-confidence path; explicit UI surface.
///
/// Surfaced as a single plugin in the marketplace because users think of
/// them as "the thing that swaps words I don't want for words I do." The
/// two engines are kept as separate internal objects (`TypoFixer` and
/// `StyleGuide`) so their UX models — silent-inline vs popover — remain
/// honest. Sharing a single event subscription would force one UX model
/// onto both, which is the wrong simplification.
///
/// Migration: previous installations toggled `com.halen.typo-fixer` and
/// `com.halen.style-guide` independently. `PluginRegistry` migrates the
/// new id's enabled-state from either of the old ids on first launch —
/// see `PluginRegistry.readPersistedEnabled`.
@MainActor
final class WordReplacements: HalenPlugin {
    let id = "com.halen.word-replacements"
    let name = "Word Replacements"
    let summary = "Fixes your typos. Swaps in your preferred terms."
    let icon = "character.cursor.ibeam"
    let category: PluginCategory = .writing

    /// Auto-corrects typos inline. Started/stopped alongside this wrapper.
    let typoFixer: TypoFixer
    /// Surfaces user-defined banned → preferred rules via popover.
    let styleGuide: StyleGuide

    init(services: HalenServices, typoStore: TypoStore) {
        self.typoFixer = TypoFixer(services: services, store: typoStore)
        self.styleGuide = StyleGuide(services: services)
    }

    func start() {
        typoFixer.start()
        styleGuide.start()
    }

    func stop() {
        typoFixer.stop()
        styleGuide.stop()
    }

    func makeDetailView() -> AnyView {
        AnyView(
            WordReplacementsDetailView(
                typoStore: typoFixer.storeForDetailView,
                styleStore: styleGuide.store
            )
        )
    }
}

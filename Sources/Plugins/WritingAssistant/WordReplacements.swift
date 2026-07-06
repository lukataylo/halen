import HalenPluginAPI
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
/// Surfaced as the Writing Assistant's Corrections tab because users think of
/// them as "the thing that swaps words I don't want for words I do." The
/// two engines are kept as separate internal objects (`TypoFixer` and
/// `StyleGuide`) so their UX models — silent-inline vs popover — remain
/// honest. Sharing a single event subscription would force one UX model
/// onto both, which is the wrong simplification.
@MainActor
final class WordReplacements {
    /// Auto-corrects typos inline. Started/stopped alongside this wrapper.
    let typoFixer: TypoFixer
    /// Surfaces user-defined banned → preferred rules via popover.
    let styleGuide: StyleGuide

    init(context: PluginContext, typoStore: TypoStore) {
        self.typoFixer = TypoFixer(context: context, store: typoStore)
        self.styleGuide = StyleGuide(context: context)
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

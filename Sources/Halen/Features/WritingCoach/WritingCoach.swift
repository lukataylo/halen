import SwiftUI

/// Paragraph-level writing critique — the user-facing rollup of two
/// classifiers that both inspect each settled paragraph:
///
///   1. **Tone** — was Sentiment Guard. Flags hostile / irritated /
///      passive-aggressive language and offers a Gemma rephrase.
///   2. **Clarity** — was Clarity Checker. Flags passive voice, run-on
///      sentences, vague pronouns. Same rephrase action.
///
/// Surfaced as one plugin because users think of them as "the thing that
/// reads my paragraph and tells me if it's any good". Two separate
/// marketplace rows + two enable toggles + two popovers competing for
/// the same paragraph was the surface area we're cutting.
///
/// Wrapper-not-rewrite: the two engines keep their own ParagraphClassifier
/// instances, prompt construction, and rule stores so the merge is
/// non-destructive. A real fusion that runs one Qwen call against both
/// rule sets is a follow-up — would roughly halve per-paragraph latency
/// but needs the prompts redesigned.
///
/// Migration: PluginRegistry.readPersistedEnabled migrates the new id
/// from either of `com.halen.sentiment-guard` / `com.halen.clarity-checker`
/// on first launch, same pattern as Word Replacements.
@MainActor
final class WritingCoach: HalenPlugin {
    let id = "com.halen.writing-coach"
    let name = "Writing Coach"
    let summary = "Flags hostile tone, passive voice, and run-ons before you send."
    let icon = "text.magnifyingglass"
    let category: PluginCategory = .writing

    let sentimentGuard: SentimentGuard
    let clarityChecker: ClarityChecker

    init(services: HalenServices) {
        self.sentimentGuard = SentimentGuard(services: services)
        self.clarityChecker = ClarityChecker(services: services)
    }

    func start() {
        sentimentGuard.start()
        clarityChecker.start()
    }

    func stop() {
        sentimentGuard.stop()
        clarityChecker.stop()
    }

    func makeDetailView() -> AnyView {
        AnyView(
            WritingCoachDetailView(
                sentiment: sentimentGuard,
                clarity: clarityChecker
            )
        )
    }
}

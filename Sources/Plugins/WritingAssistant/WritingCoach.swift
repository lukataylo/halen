import HalenPluginAPI

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
/// WritingCoach is an internal start/stop wrapper only — it isn't a plugin.
/// Its engines are surfaced as the Writing Assistant's top-level Tone and
/// Clarity tabs (see WritingAssistant.makeDetailView).
@MainActor
final class WritingCoach {
    let sentimentGuard: SentimentGuard
    let clarityChecker: ClarityChecker

    init(context: PluginContext) {
        self.sentimentGuard = SentimentGuard(context: context)
        self.clarityChecker = ClarityChecker(context: context)
    }

    func start() {
        sentimentGuard.start()
        clarityChecker.start()
    }

    func stop() {
        sentimentGuard.stop()
        clarityChecker.stop()
    }
}

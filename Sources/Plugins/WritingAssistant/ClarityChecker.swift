import HalenPluginAPI
import SwiftUI

/// Watches `text.pause` events and, when the user settles, asks Gemma which
/// enabled clarity rules the paragraph at the caret violates (passive voice,
/// run-ons, vague pronouns, …). Findings are published on the event bus; the
/// host's overlay tints the caret indicator and backs the hover popover.
@MainActor
final class ClarityChecker {
    /// Event `source` id for findings — kept at the engine's old plugin id so
    /// finding sources stay stable across the plugin-platform migration.
    private let sourceId = "com.halen.clarity-checker"

    /// Strict / balanced / lax — same idea as SentimentGuard. Pushed into
    /// the classifier prompt as a single sentence; we don't have logits to
    /// threshold against, so prompt shaping is the lever.
    enum Sensitivity: String, CaseIterable, Sendable {
        case strict, balanced, lax
    }
    static let sensitivityKey = "halen.clarity-checker.sensitivity"
    static var sensitivity: Sensitivity {
        let raw = UserDefaults.standard.string(forKey: sensitivityKey) ?? ""
        return Sensitivity(rawValue: raw) ?? .balanced
    }
    static func sensitivityClause(_ s: Sensitivity) -> String {
        switch s {
        case .strict:
            return "Be sensitive — surface any rule the text plausibly violates, even when borderline."
        case .balanced:
            return "Only list a rule when the text clearly violates it; when in doubt, leave it off."
        case .lax:
            return "Only list a rule when the violation is unambiguous and material; ignore minor or stylistic edges."
        }
    }

    /// "Ask before rewrite" (default — findings offer a rewrite action) vs
    /// "Just flag" (informational only; the user copies passages manually).
    /// No "auto-rewrite" mode — auto-replacing the user's paragraph is
    /// hostile by default and would need its own undo path before we could
    /// ship it. Currently only read by `ClarityCheckerDetailView`; the
    /// legacy popup that consumed it at runtime was removed with the
    /// passive indicator + hover model.
    enum SuggestionMode: String, CaseIterable, Sendable {
        case askBeforeRewrite     // default
        case flagOnly             // no rewrite action surfaced
    }
    static let suggestionModeKey = "halen.clarity-checker.suggestionMode"
    static var suggestionMode: SuggestionMode {
        let raw = UserDefaults.standard.string(forKey: suggestionModeKey) ?? ""
        return SuggestionMode(rawValue: raw) ?? .askBeforeRewrite
    }

    private let context: PluginContext
    let rulesStore: ClarityRulesStore
    private let classifier = ParagraphClassifier()

    private var task: Task<Void, Never>?
    private var lastCaretRect: CGRect?
    private(set) var flaggedThisSession = 0

    init(context: PluginContext) {
        self.context = context
        // The engines share the Writing Assistant's single storage directory,
        // so each rule store gets its own filename instead of the per-engine
        // directory the old per-plugin ids provided.
        let dir = context.storage.directory
        self.rulesStore = ClarityRulesStore(fileURL: dir.appending(path: "clarity-rules.json"))
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [events = context.events, weak self] in
            for await event in events.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let p):
                    self.lastCaretRect = CGRect(x: p.rect.x, y: p.rect.y,
                                                width: p.rect.width, height: p.rect.height)
                case .textPaused(let p):
                    self.schedule(text: p.text, caretOffset: p.caretOffset,
                                  appBundleId: p.appBundleId)
                default:
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        classifier.cancel()
    }

    func makeDetailView() -> AnyView {
        AnyView(ClarityCheckerDetailView(rulesStore: rulesStore, flaggedCount: flaggedThisSession))
    }

    // MARK: - Classification

    private func schedule(text: String, caretOffset: Int, appBundleId: String) {
        classifier.schedule(
            text: text,
            caretOffset: caretOffset,
            eligibility: { [weak self] paragraph in
                guard let self, !self.rulesStore.enabledRules.isEmpty else { return false }
                // Only judged once the paragraph reads as a finished thought.
                return paragraph.contains(where: { $0 == "." || $0 == "?" || $0 == "!" })
            },
            classify: { [weak self] paragraph in
                await self?.runClassification(paragraph: paragraph, appBundleId: appBundleId)
            }
        )
    }

    private func runClassification(paragraph: String, appBundleId: String) async {
        let enabled = rulesStore.enabledRules
        guard !enabled.isEmpty else { return }
        // Snapshot the anchor now — the Gemma call below may take a few seconds.
        let anchor = CaretAnchoredPanel.resolveAnchor(
            element: context.text?.focusedElement, cachedCaretRect: lastCaretRect)

        let rulesBlock = enabled.map { "- \($0.id): \($0.prompt)" }.joined(separator: "\n")
        // Neutral fallback when the tone-profiles capability is revoked.
        let toneClause = (context.toneProfiles?.profile(for: appBundleId) ?? .neutral).promptClause
        let sensitivityClause = Self.sensitivityClause(Self.sensitivity)
        let prompt = """
        You are a writing-clarity checker. The text below may have one or more of these issues:
        \(rulesBlock)

        \(toneClause)
        \(sensitivityClause)

        Reply with ONLY a comma-separated list of the ids that genuinely apply, or the word none. No other text.

        Text: \"\"\"\(paragraph)\"\"\"
        """
        // `.classifier` routes to the dedicated Qwen 0.5B classifier — fast
        // enough to make text.pause → popover land sub-second. Output is a
        // short comma-separated list of rule ids (longest plausible:
        // "passive_voice, run_on, dangling_modifier, vague_pronoun, hedging"
        // = ~32 BPE tokens). 32 is the right cap; 40 was the historical
        // pre-Qwen value.
        let request = InferenceRequest(prompt: prompt, tier: .classifier, maxTokens: 32,
                                       temperature: 0.1, taskKind: .classification)
        do {
            let response = try await context.inference.complete(request)
            let ids = parseIds(response.text, valid: Set(enabled.map(\.id)))
            Log.info("ClarityChecker: \(ids.count) issue(s) (\(response.latencyMs)ms)")
            if ids.isEmpty {
                // No issues — clear any prior finding for this paragraph so
                // the indicator tint disappears.
                context.events.publish(.findingsCleared(.init(
                    source: sourceId, id: nil, timestamp: Date())))
                return
            }
            publishFinding(paragraph: paragraph,
                           rules: enabled.filter { ids.contains($0.id) },
                           appBundleId: appBundleId, anchor: anchor)
        } catch {
            Log.warn("ClarityChecker: inference failed: \(error)")
        }
    }

    // MARK: - Finding emission

    /// Publish a `.findingDetected` on the shared event bus. `OverlayController`
    /// renders the severity tint; the popup-on-classification is gone in
    /// favour of the passive cursor-indicator + hover model.
    private func publishFinding(paragraph: String, rules: [ClarityRule],
                                appBundleId: String,
                                anchor: CaretAnchoredPanel.Anchor?) {
        flaggedThisSession += 1
        let summary = rules.count == 1
            ? "1 clarity issue"
            : "\(rules.count) clarity issues"
        let hash = sha256Hex(paragraph)
        let anchorRect = anchor.map { Event.CaretRect(
            x: $0.rect.minX, y: $0.rect.minY,
            width: $0.rect.width, height: $0.rect.height) }
            ?? Event.CaretRect(x: 0, y: 0, width: 0, height: 0)
        context.events.publish(.findingDetected(.init(
            id: "\(sourceId):\(hash.prefix(12))",
            source: sourceId,
            severity: .clarity,
            summary: summary,
            anchor: anchorRect,
            paragraphHash: hash,
            appBundleId: appBundleId,
            timestamp: Date()
        )))
    }

    /// Pull valid rule ids out of the model's reply. Tolerant of stray words /
    /// punctuation; `none` (anywhere in the reply) means no findings.
    private func parseIds(_ raw: String, valid: Set<String>) -> Set<String> {
        let lowered = raw.lowercased()
        if lowered.contains("none") { return [] }
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && $0 != "_" }).map(String.init)
        return Set(tokens.filter { valid.contains($0) })
    }
}

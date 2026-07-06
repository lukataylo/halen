import AppKit
import SwiftUI

/// Watches `text.pause` events and, when the user settles, asks Gemma which
/// enabled clarity rules the paragraph at the caret violates (passive voice,
/// run-ons, vague pronouns, …). Matches surface in the shared `FindingsPopover`
/// with a "Rewrite via Gemma 4" action that drops a cleaned rewrite on the
/// clipboard.
///
/// Inline Grammarly-style underlines would need an AX overlay system that
/// doesn't exist yet; the caret-anchored popover is the pragmatic v1 and keeps
/// the plugin consistent with Sentiment Guard.
@MainActor
final class ClarityChecker: HalenPlugin {
    let id = "com.halen.clarity-checker"
    let name = "Clarity Checker"
    let summary = "Flags passive voice, run-ons, and vague writing as you type."
    let icon = "text.magnifyingglass"
    let category: PluginCategory = .writing

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

    /// "Ask before rewrite" (default — popup with rewrite action) vs
    /// "Just flag" (the popup is informational only; the user copies
    /// passages manually). No "auto-rewrite" mode — auto-replacing the
    /// user's paragraph is hostile by default and would need its own
    /// undo path before we could ship it.
    enum SuggestionMode: String, CaseIterable, Sendable {
        case askBeforeRewrite     // default
        case flagOnly             // no rewrite action surfaced
    }
    static let suggestionModeKey = "halen.clarity-checker.suggestionMode"
    static var suggestionMode: SuggestionMode {
        let raw = UserDefaults.standard.string(forKey: suggestionModeKey) ?? ""
        return SuggestionMode(rawValue: raw) ?? .askBeforeRewrite
    }

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?
    let rulesStore: ClarityRulesStore
    private let classifier = ParagraphClassifier()

    private var task: Task<Void, Never>?
    private var lastCaretRect: CGRect?
    private var activePanel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private(set) var flaggedThisSession = 0

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
        let dir = services.storageDirectory(for: "com.halen.clarity-checker")
        self.rulesStore = ClarityRulesStore(fileURL: dir.appending(path: "rules.json"))
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [services, weak self] in
            for await event in services.eventBus.subscribe() {
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
        dismissTask?.cancel()
        activePanel?.orderOut(nil)
        activePanel = nil
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
            caretObserver: caretObserver, cachedCaretRect: lastCaretRect)

        let rulesBlock = enabled.map { "- \($0.id): \($0.prompt)" }.joined(separator: "\n")
        let toneClause = services.toneProfiles.profile(for: appBundleId).promptClause
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
            let response = try await services.inference.complete(request)
            let ids = parseIds(response.text, valid: Set(enabled.map(\.id)))
            Log.info("ClarityChecker: \(ids.count) issue(s) (\(response.latencyMs)ms)")
            if ids.isEmpty {
                // No issues — clear any prior finding for this paragraph so
                // the indicator tint disappears.
                services.eventBus.publish(.findingsCleared(.init(
                    source: id, id: nil, timestamp: Date())))
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
        services.eventBus.publish(.findingDetected(.init(
            id: "\(id):\(hash.prefix(12))",
            source: id,
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

    // MARK: - Popup

    private func showPopup(paragraph: String, rules: [ClarityRule],
                           anchor: CaretAnchoredPanel.Anchor?) {
        guard !rules.isEmpty else { return }
        flaggedThisSession += 1
        activePanel?.orderOut(nil)
        dismissTask?.cancel()

        let findings = rules.map {
            Finding(id: $0.id, title: $0.label, detail: $0.prompt, colorName: "blue")
        }
        // Height grows with the findings list, capped so it never dominates.
        let height = CGFloat(min(330, 150 + rules.count * 46))
        let size = CGSize(width: 360, height: height)

        let panel = HalenFloatingPanel.make(
            size: NSSize(width: size.width, height: size.height),
            level: .floating, interactive: true, shadow: true)

        // "Flag only" mode strips the rewrite action entirely — the popup
        // becomes informational, and the user copies passages themselves.
        // Default mode keeps the streaming Gemma rewrite.
        let mode = Self.suggestionMode
        let view = FindingsPopover(
            icon: "text.magnifyingglass",
            headline: rules.count == 1 ? "1 clarity issue" : "\(rules.count) clarity issues",
            headlineColorName: "blue",
            findings: findings,
            primaryActionLabel: mode == .askBeforeRewrite ? "Rewrite" : nil,
            onPrimaryAction: mode == .askBeforeRewrite
                ? { [weak self] in
                    self?.rewrite(paragraph: paragraph)
                    self?.closePanel()
                }
                : nil,
            onDismiss: { [weak self] in self?.closePanel() }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrame(CaretAnchoredPanel.frame(for: anchor, size: size), display: true)
        panel.orderFrontRegardless()
        activePanel = panel

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { self?.closePanel() }
        }
    }

    private func closePanel() {
        activePanel?.orderOut(nil)
        activePanel = nil
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Rewrite the flagged paragraph addressing every clarity issue, and drop
    /// the result on the clipboard (same pattern as SentimentGuard's rephrase).
    private func rewrite(paragraph: String) {
        Task { @MainActor [services] in
            let prompt = """
            Rewrite the following text to be clearer and more direct — fix passive voice, run-on sentences, dangling modifiers, and vague phrasing while keeping the original meaning. Output only the rewrite, no preamble, no quotes.

            Text:
            \(paragraph)
            """
            let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 500,
                                           temperature: 0.4, taskKind: .generation)
            do {
                let response = try await services.inference.complete(request)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(response.text.unwrappedModelText, forType: .string)
                Log.info("ClarityChecker: rewrite copied to clipboard (\(response.latencyMs)ms)")
            } catch {
                Log.warn("ClarityChecker: rewrite failed: \(error)")
            }
        }
    }
}

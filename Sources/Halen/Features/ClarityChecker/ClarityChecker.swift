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
        let prompt = """
        You are a writing-clarity checker. The text below may have one or more of these issues:
        \(rulesBlock)

        \(toneClause)

        Reply with ONLY a comma-separated list of the ids that genuinely apply, or the word none. No other text.

        Text: \"\"\"\(paragraph)\"\"\"
        """
        let request = InferenceRequest(prompt: prompt, tier: .small, maxTokens: 40,
                                       temperature: 0.1, taskKind: .classification)
        do {
            let response = try await services.inference.complete(request)
            let ids = parseIds(response.text, valid: Set(enabled.map(\.id)))
            Log.info("ClarityChecker: \(ids.count) issue(s) (\(response.latencyMs)ms)")
            guard !ids.isEmpty else { return }
            showPopup(paragraph: paragraph,
                      rules: enabled.filter { ids.contains($0.id) },
                      anchor: anchor)
        } catch {
            Log.warn("ClarityChecker: inference failed: \(error)")
        }
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

        let view = FindingsPopover(
            icon: "text.magnifyingglass",
            headline: rules.count == 1 ? "1 clarity issue" : "\(rules.count) clarity issues",
            headlineColorName: "blue",
            findings: findings,
            primaryActionLabel: "Rewrite via Gemma 4",
            onPrimaryAction: { [weak self] in
                self?.rewrite(paragraph: paragraph)
                self?.closePanel()
            },
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

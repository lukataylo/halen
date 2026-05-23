import AppKit
import SwiftUI
import Foundation

/// Watches `text.pause` events. When the text looks like a draft message (sentence-
/// ending punctuation, >60 chars) the local Gemma 4 instance classifies its tone.
/// "Irritated" or "hostile" surfaces a small popover near the caret with two
/// options: dismiss-and-remember (won't re-flag this exact text), or rephrase
/// (Gemma rewrites; result lands on the clipboard for paste).
///
/// Approved fingerprints persist to disk so the same text never re-flags across
/// sessions.
@MainActor
final class SentimentGuard: HalenPlugin {
    let id = "com.halen.sentiment-guard"
    let name = "Sentiment Guard"
    let summary = "Warns you before sending something that reads as angry or hostile."
    let icon = "exclamationmark.bubble"
    let category: PluginCategory = .writing

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?
    let rulesStore: SentimentRulesStore
    private var task: Task<Void, Never>?

    /// Owns the typing-settle debounce, paragraph extraction, and dedup of
    /// recently-classified paragraphs. Plugin-specific concerns (cooldown,
    /// approvedHashes, prompt, popup) stay here.
    private let classifier = ParagraphClassifier()

    /// Per-app cooldown set when the user dismisses the popup — "I've seen the
    /// warning, stop nagging me in this app for a while." Also bumped on the
    /// 12 s auto-dismiss (the user ignored the popup; treat it the same).
    /// In-memory: a fresh launch starts with no cooldowns.
    private var cooldownUntil: [String: Date] = [:]
    private static let dismissCooldown: TimeInterval = 10 * 60

    /// UserDefaults key for the conciseness-check toggle (see
    /// `SentimentGuardDetailView`). The check is on by default.
    static let concisenessDefaultsKey = "halen.sentiment-guard.conciseness"
    static var concisenessEnabled: Bool {
        UserDefaults.standard.object(forKey: concisenessDefaultsKey) as? Bool ?? true
    }

    /// Popup footprint: compact while it only shows the warning + actions;
    /// taller once the user asks for a rephrase and the streaming preview pane
    /// appears. SentimentGuard uses these to size the host `NSPanel`; the
    /// SwiftUI `FindingsPopover` inside grows to fill the available height.
    static let popupIdleSize = NSSize(width: 360, height: 170)
    static let popupRephraseSize = NSSize(width: 360, height: 330)
    /// Hashes the user explicitly approved as fine. Persisted.
    private var approvedHashes: Set<String> = []
    /// Number of times we surfaced a popover this session (any rule). In-memory only.
    private(set) var flaggedThisSession: Int = 0
    /// Most recent caret rect from `caret.moved` events; used to anchor the popover.
    private var lastCaretRect: CGRect?
    private var activePanel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Live state for the in-popup streaming rephrase. Non-nil only while a
    /// popup is on screen; `FindingsPopover` observes it via `@ObservedObject`.
    private var rephraseState: StreamingRewriteState?
    private var rephraseTask: Task<Void, Never>?
    /// Anchor used to place the current popup — kept so the panel can be
    /// re-framed (and re-clamped to screen) when it grows for the rephrase pane.
    private var activeAnchor: CaretAnchoredPanel.Anchor?

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
        let storageDir = services.storageDirectory(for: "com.halen.sentiment-guard")
        self.rulesStore = SentimentRulesStore(fileURL: storageDir.appending(path: "rules.json"))
        loadApproved()
    }

    func makeDetailView() -> AnyView {
        AnyView(
            SentimentGuardDetailView(
                rulesStore: rulesStore,
                approvedCount: approvedHashes.count,
                flaggedCount: flaggedThisSession,
                onClearApproved: { [weak self] in
                    self?.approvedHashes.removeAll()
                    self?.saveApproved()
                }
            )
        )
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [services, weak self] in
            for await event in services.eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let payload):
                    self.lastCaretRect = CGRect(x: payload.rect.x, y: payload.rect.y,
                                                width: payload.rect.width, height: payload.rect.height)
                case .textPaused(let payload):
                    self.scheduleClassification(text: payload.text,
                                                caretOffset: payload.caretOffset,
                                                appBundleId: payload.appBundleId)
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
        rephraseTask?.cancel()
        rephraseTask = nil
        rephraseState = nil
        activePanel?.orderOut(nil)
        activePanel = nil
    }

    // MARK: - Evaluation

    /// Hand off to `ParagraphClassifier`, which owns settle-debounce + paragraph
    /// extraction + hash dedup. The closures carry SentimentGuard's specific
    /// concerns: per-app cooldown, persistent approved-fingerprint allowlist,
    /// the sentence-end-punctuation eligibility check, and the actual Gemma
    /// classification + popup.
    private func scheduleClassification(text: String, caretOffset: Int, appBundleId: String) {
        classifier.schedule(
            text: text,
            caretOffset: caretOffset,
            eligibility: { [weak self] paragraph in
                guard let self else { return false }
                // Opportunistic cooldown prune + per-app gate.
                let now = Date()
                self.cooldownUntil = self.cooldownUntil.filter { $0.value > now }
                if self.cooldownUntil[appBundleId] != nil { return false }
                // Drafts only — a paragraph without sentence-ending punctuation
                // is mid-thought and likely to mis-classify.
                guard paragraph.contains(where: { $0 == "." || $0 == "?" || $0 == "!" }) else {
                    return false
                }
                // Permanent allowlist — user clicked "Looks fine" on this exact
                // paragraph in a past session.
                return !self.approvedHashes.contains(sha256Hex(paragraph))
            },
            classify: { [weak self] paragraph in
                await self?.runGemmaClassification(paragraph: paragraph, appBundleId: appBundleId)
            }
        )
    }

    /// The Gemma half of classification: build the multi-rule prompt, run it,
    /// surface the popup if the verdict matches an enabled rule. The
    /// already-seen dedup is handled by `ParagraphClassifier` upstream.
    private func runGemmaClassification(paragraph: String, appBundleId: String) async {
        let enabled = rulesStore.enabledRules
        guard !enabled.isEmpty else { return }

        // Snapshot the caret anchor NOW — the classifier has just settled, so
        // the caret is sitting at the end of the sentence we're about to
        // judge. The Gemma call below takes 1–4 s; by the time it returns the
        // user may have moved the caret, scrolled, or switched fields, and
        // anchoring then would float the popup far from the text it's about.
        let anchorSnapshot = CaretAnchoredPanel.resolveAnchor(
            caretObserver: caretObserver, cachedCaretRect: lastCaretRect)

        let categoriesBlock = enabled
            .map { "- \($0.label.lowercased()): \($0.prompt)" }
            .joined(separator: "\n")
        // Bias the classifier by the app's tone profile — a blunt Slack
        // message shouldn't be judged the way a blunt email is.
        let toneClause = services.toneProfiles.profile(for: appBundleId).promptClause
        let prompt = """
        You are a tone classifier. Categorise the tone of the following text as one of these labels:
        \(categoriesBlock)
        - neutral: the text doesn't strongly match any of the above

        \(toneClause)

        Reply with ONLY the matching label, lowercase, no punctuation, no preamble.

        Text: \"\"\"\(paragraph)\"\"\"
        """

        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 16,
                                       temperature: 0.1, taskKind: .classification)
        do {
            let response = try await services.inference.complete(request)
            let label = response.text.modelLabelToken
            Log.info("SentimentGuard: \(label) (\(response.latencyMs)ms)")
            // Conciseness check — a zero-cost rule-based scan that runs
            // alongside the tone classifier, gated by a Settings toggle.
            let fillers = Self.concisenessEnabled ? FillerPhrases.scan(paragraph) : []
            if let matched = enabled.first(where: { $0.label.lowercased() == label }) {
                showPopup(text: paragraph, rule: matched, fillers: fillers,
                          hash: sha256Hex(paragraph), appBundleId: appBundleId,
                          anchor: anchorSnapshot)
            } else if !fillers.isEmpty {
                // No tone match, but wordy phrasing is still worth surfacing.
                showPopup(text: paragraph, rule: nil, fillers: fillers,
                          hash: sha256Hex(paragraph), appBundleId: appBundleId,
                          anchor: anchorSnapshot)
            }
        } catch {
            Log.warn("SentimentGuard: inference failed: \(error)")
        }
    }

    // MARK: - Popup

    private func showPopup(text: String, rule: SentimentRule?, fillers: [FillerMatch],
                           hash: String, appBundleId: String,
                           anchor: CaretAnchoredPanel.Anchor? = nil) {
        flaggedThisSession += 1
        activePanel?.orderOut(nil)
        dismissTask?.cancel()

        // Wordy phrases become findings; a matched tone rule is the headline.
        // With no tone match the conciseness count is the headline instead.
        let findings = fillers.map {
            Finding(title: "“\($0.phrase)”",
                    detail: "Consider: \($0.suggestion)",
                    colorName: "yellow")
        }
        let headline: String
        let headlineColor: String
        let icon: String
        if let rule {
            headline = "This reads as \(rule.label)"
            headlineColor = rule.colorName
            icon = "exclamationmark.bubble.fill"
        } else {
            headline = findings.count == 1 ? "1 wordy phrase" : "\(findings.count) wordy phrases"
            headlineColor = "yellow"
            icon = "scissors"
        }

        // Start at the idle size; `beginRephrase` grows the panel to
        // `popupRephraseSize` once the user taps the streaming action.
        let panel = HalenFloatingPanel.make(
            size: Self.popupIdleSize,
            level: .floating,
            interactive: true,
            shadow: true
        )

        let state = StreamingRewriteState()
        rephraseState = state

        let view = FindingsPopover(
            icon: icon,
            headline: headline,
            headlineColorName: headlineColor,
            contextPreview: text,
            findings: findings,
            primaryActionLabel: "Rephrase via Gemma 4",
            // Rephrase no longer closes the popup — it streams the rewrite
            // into the preview pane in place.
            onPrimaryAction: { [weak self] in
                self?.beginRephrase(originalText: text)
            },
            approveLabel: "Looks fine",
            onApprove: { [weak self] in
                self?.approve(hash: hash)
                self?.closePanel()
            },
            streaming: state,
            onCopy: { [weak self] in
                self?.copyRephrase()
            },
            onDismiss: { [weak self] in
                self?.recordDismiss(appBundleId: appBundleId)
                self?.closePanel()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        // Use the snapshot taken at classification time; only fall back to a
        // fresh resolve if we never got one (shouldn't happen in practice).
        // Cache it on `activeAnchor` so `resizePopup` can re-clamp the frame
        // to the same screen when the panel grows for the streaming pane.
        let resolved = anchor ?? CaretAnchoredPanel.resolveAnchor(
            caretObserver: caretObserver, cachedCaretRect: lastCaretRect)
        activeAnchor = resolved
        panel.setFrame(CaretAnchoredPanel.frame(for: resolved,
                                                size: CGSize(width: Self.popupIdleSize.width,
                                                             height: Self.popupIdleSize.height)),
                       display: true)
        panel.orderFrontRegardless()

        activePanel = panel

        dismissTask = Task { @MainActor [weak self, appBundleId] in
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled {
                // Auto-dismiss = the user ignored the popup; treat it the same
                // as an explicit dismiss and don't immediately re-pop-up.
                self?.recordDismiss(appBundleId: appBundleId)
                self?.closePanel()
            }
        }
    }

    private func closePanel() {
        activePanel?.orderOut(nil)
        activePanel = nil
        dismissTask?.cancel()
        dismissTask = nil
        rephraseTask?.cancel()
        rephraseTask = nil
        rephraseState = nil
        activeAnchor = nil
    }

    private func approve(hash: String) {
        approvedHashes.insert(hash)
        saveApproved()
    }

    /// User explicitly (or implicitly, via auto-dismiss) closed the popup.
    /// Mute this app for the cooldown window — they've seen the warning, and
    /// re-popping every keystroke pause is noise.
    private func recordDismiss(appBundleId: String) {
        cooldownUntil[appBundleId] = Date().addingTimeInterval(Self.dismissCooldown)
        Log.info("SentimentGuard: muted in \(appBundleId) for \(Int(Self.dismissCooldown / 60)) min after dismiss")
    }

    /// Stream a calmer rewrite of `originalText` into the popup's preview pane.
    /// The popup grows to fit the pane and tokens appear as the local model
    /// produces them; the result lands on the clipboard when the user taps Copy.
    private func beginRephrase(originalText: String) {
        guard let state = rephraseState else { return }
        // The user is engaged now — stop the 12 s auto-dismiss.
        dismissTask?.cancel()
        dismissTask = nil
        rephraseTask?.cancel()

        state.rewrite = ""
        state.phase = .streaming
        resizePopup(to: Self.popupRephraseSize)

        let prompt = """
        Rewrite the following message in a calmer, more constructive tone while keeping the original intent and length. Output only the rewritten text — no quotes, no preamble.

        Message: \"\"\"\(originalText)\"\"\"
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 400,
                                       temperature: 0.5, taskKind: .generation)

        rephraseTask = Task { @MainActor [services, weak self] in
            do {
                for try await snapshot in services.inference.stream(request) {
                    guard !Task.isCancelled, let state = self?.rephraseState else { return }
                    state.rewrite = snapshot
                }
                guard let state = self?.rephraseState else { return }
                // Intermediate snapshots were raw; clean wrapper quotes off the
                // final text.
                let final = state.rewrite.unwrappedModelText
                state.rewrite = final
                state.phase = final.isEmpty ? .failed : .done
                Log.info("SentimentGuard: rephrase streamed complete (\(final.count) chars)")
            } catch is CancellationError {
                // Popup closed mid-stream — nothing to surface.
            } catch {
                self?.rephraseState?.phase = .failed
                Log.warn("SentimentGuard: rephrase failed: \(error)")
            }
        }
    }

    /// Copy the streamed rewrite to the clipboard and close the popup.
    private func copyRephrase() {
        guard let rewrite = rephraseState?.rewrite, !rewrite.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rewrite, forType: .string)
        Log.info("SentimentGuard: rephrase copied to clipboard")
        closePanel()
    }

    /// Re-frame the live panel to `size`, re-clamped to the screen around the
    /// anchor resolved when the popup opened.
    private func resizePopup(to size: NSSize) {
        guard let panel = activePanel else { return }
        let frame = CaretAnchoredPanel.frame(
            for: activeAnchor,
            size: CGSize(width: size.width, height: size.height))
        panel.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Persistence

    private var approvedFileURL: URL {
        services.storageDirectory(for: id).appending(path: "approved.json")
    }

    private func loadApproved() {
        guard let data = try? Data(contentsOf: approvedFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        approvedHashes = Set(list)
        Log.info("SentimentGuard: loaded \(approvedHashes.count) approved fingerprints")
    }

    private func saveApproved() {
        let list = Array(approvedHashes).sorted()
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: approvedFileURL, options: .atomic)
    }
}


// The popover UI now lives in the shared `FindingsPopover` (Features/),
// with SentimentGuard supplying the single-finding configuration in `showPopup`
// and `StreamingRewriteState` driving the live rephrase pane.

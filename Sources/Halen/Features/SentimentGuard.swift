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
    /// Hashes the user explicitly approved as fine. Persisted.
    private var approvedHashes: Set<String> = []
    /// Number of times we surfaced a popover this session (any rule). In-memory only.
    private(set) var flaggedThisSession: Int = 0
    /// Most recent caret rect from `caret.moved` events; used to anchor the popover.
    private var lastCaretRect: CGRect?
    private var activePanel: NSPanel?
    private var dismissTask: Task<Void, Never>?

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
        let anchorSnapshot = anchorRect()

        let categoriesBlock = enabled
            .map { "- \($0.label.lowercased()): \($0.prompt)" }
            .joined(separator: "\n")
        let prompt = """
        You are a tone classifier. Categorise the tone of the following text as one of these labels:
        \(categoriesBlock)
        - neutral: the text doesn't strongly match any of the above

        Reply with ONLY the matching label, lowercase, no punctuation, no preamble.

        Text: \"\"\"\(paragraph)\"\"\"
        """

        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 16,
                                       temperature: 0.1, taskKind: .classification)
        do {
            let response = try await services.inference.complete(request)
            let label = normalizeLabel(response.text)
            Log.info("SentimentGuard: \(label) (\(response.latencyMs)ms)")
            if let matched = enabled.first(where: { $0.label.lowercased() == label }) {
                showPopup(text: paragraph, rule: matched,
                          hash: sha256Hex(paragraph), appBundleId: appBundleId,
                          anchor: anchorSnapshot)
            }
        } catch {
            Log.warn("SentimentGuard: inference failed: \(error)")
        }
    }

    private func normalizeLabel(_ raw: String) -> String {
        raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".\"' `"))
            .components(separatedBy: .whitespacesAndNewlines)
            .first ?? raw.lowercased()
    }

    // MARK: - Popup

    private func showPopup(text: String, rule: SentimentRule, hash: String,
                           appBundleId: String, anchor: AnchorResult? = nil) {
        let label = rule.label.lowercased()
        flaggedThisSession += 1
        activePanel?.orderOut(nil)
        dismissTask?.cancel()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = SentimentGuardPopup(
            text: text,
            label: label,
            tone: rule.colorName,
            onDismiss: { [weak self] in
                self?.recordDismiss(appBundleId: appBundleId)
                self?.closePanel()
            },
            onApprove: { [weak self] in
                self?.approve(hash: hash)
                self?.closePanel()
            },
            onRephrase: { [weak self] in
                self?.rephrase(originalText: text)
                self?.closePanel()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        let popupSize = CGSize(width: 360, height: 170)
        // Use the snapshot taken at classification time; only fall back to a
        // fresh resolve if we never got one (shouldn't happen in practice).
        panel.setFrame(popupFrame(for: anchor ?? anchorRect(), size: popupSize), display: true)
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

    /// Resolve where to anchor the popup. Tries progressively coarser anchors
    /// so apps with poor AX support (Electron, browser text fields, Notion)
    /// don't fall through to a screen-corner pin — the popup should always
    /// appear near the work the user was doing, not floating off in the
    /// bottom-right of the display.
    ///
    /// Each step's rect is validated against the screen list because some
    /// apps misreport AX bounds in window-local coords; pinning the popup
    /// to those would put it at (0,0).
    private func anchorRect() -> AnchorResult? {
        // 1. Exact caret bounds — the ideal: popup pops right below the caret.
        if let element = caretObserver?.currentElement,
           let axRect = axReadCaretBounds(element) {
            let cocoa = axRectToCocoa(axRect)
            if rectIsOnScreen(cocoa) { return .init(rect: cocoa, kind: .caret) }
        }
        // 2. Cached caret rect from the most recent caret.moved event.
        if let cached = lastCaretRect, cached.width > 0 || cached.height > 0,
           rectIsOnScreen(cached) {
            return .init(rect: cached, kind: .caret)
        }
        // 3. The focused element's frame. Electron / web text fields refuse
        //    to expose caret bounds but almost always expose AXFrame on the
        //    field itself — we can anchor below that field, which still lands
        //    near where the user was typing.
        if let element = caretObserver?.currentElement,
           let axFrame = axReadFrame(element) {
            let cocoa = axRectToCocoa(axFrame)
            if rectIsOnScreen(cocoa) { return .init(rect: cocoa, kind: .element) }
        }
        // 4. The containing window's frame. Last-stop "right region of the
        //    screen": at minimum we land on the app the user is in, not
        //    a different display's corner.
        if let element = caretObserver?.currentElement,
           let axWindow = axReadContainingWindowFrame(element) {
            let cocoa = axRectToCocoa(axWindow)
            if rectIsOnScreen(cocoa) { return .init(rect: cocoa, kind: .window) }
        }
        return nil
    }

    /// Tagged anchor — the *kind* of region influences placement (a caret
    /// gets a popup directly below it; an element/window anchor gets the
    /// popup at the field's bottom-left, inside the window's bounds).
    private struct AnchorResult {
        let rect: CGRect
        let kind: Kind
        enum Kind { case caret, element, window }
    }

    private func rectIsOnScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains(where: { $0.frame.intersects(rect) })
    }

    /// Place the popup near whichever anchor we resolved, clamped into the
    /// `visibleFrame` of the screen that actually contains it. Anchor kind
    /// changes the placement strategy:
    ///   - `.caret`: 25 px below the caret (closest to where the user looked).
    ///   - `.element`: 12 px below the bottom-left of the focused field.
    ///   - `.window`: bottom-left of the window's content area, 24 px inset
    ///     (Electron fallback — the window frame is the best we can get).
    /// The final fallback (no anchor at all, never reached unless we have
    /// no AX info whatsoever) lands at the centre of the main screen, not
    /// the corner: anything in the corner reads as "system notification",
    /// which is the wrong mental model.
    private func popupFrame(for anchor: AnchorResult?, size: CGSize) -> NSRect {
        if let anchor, let screen = screenContaining(anchor.rect) {
            let visible = screen.visibleFrame
            var x = anchor.rect.minX
            var y: CGFloat
            switch anchor.kind {
            case .caret:
                // Sit right under the caret with a small 10 px gap so the
                // popup reads as attached to the line the user just typed.
                // If there's no room below (caret near the screen bottom),
                // flip above the caret rather than letting the clamp drag
                // the popup back up over the text.
                let below = anchor.rect.minY - size.height - 10
                let above = anchor.rect.maxY + 10
                y = (below >= visible.minY + 8) ? below : above
            case .element:
                // No caret precision — anchor in the element's upper area
                // (where text content usually begins) rather than its
                // bottom-left, which on a tall editor is nowhere near the
                // line being typed.
                x = anchor.rect.minX + 12
                y = anchor.rect.maxY - size.height - 44
            case .window:
                // Window-anchored: nestle in the window's bottom-left inset
                // rather than directly below (windows extend to screen edges).
                x = anchor.rect.minX + 24
                y = anchor.rect.minY + 24
            }
            x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
            y = min(max(visible.minY + 8, y), visible.maxY - size.height - 8)
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            Log.info("SentimentGuard popup anchor=\(anchor.kind) rect=\(anchor.rect) frame=\(frame)")
            return frame
        }
        // No usable anchor at all. Centre on the main screen — feels like a
        // dialog, not a system toast. Screen-corner pin was the old fallback
        // and it read as "completely unrelated to what I was doing."
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            return NSRect(x: f.midX - size.width / 2,
                          y: f.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        return NSRect(x: 200, y: 200, width: size.width, height: size.height)
    }

    /// Resolve which screen the caret sits on. Uses `contains(point)` on the
    /// anchor's centre rather than `intersects(rect)` — a zero-width caret
    /// (most text fields report the caret as a vertical line) is
    /// `CGRectIsEmpty`, which fails the intersect test against every screen
    /// and silently falls back to `NSScreen.main`. On a multi-monitor setup
    /// that's a different display than the one the user is typing on, and the
    /// popup ends up clamped to the wrong screen's bounds.
    private func screenContaining(_ anchor: CGRect) -> NSScreen? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
    }

    private func closePanel() {
        activePanel?.orderOut(nil)
        activePanel = nil
        dismissTask?.cancel()
        dismissTask = nil
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

    private func rephrase(originalText: String) {
        Task { @MainActor [services] in
            let prompt = """
            Rewrite the following message in a calmer, more constructive tone while keeping the original intent and length. Output only the rewritten text — no quotes, no preamble.

            Message: \"\"\"\(originalText)\"\"\"
            """
            let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 400, temperature: 0.5, taskKind: .generation)
            do {
                let response = try await services.inference.complete(request)
                let rewritten = response.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rewritten, forType: .string)
                Log.info("SentimentGuard: rephrase copied to clipboard (\(response.latencyMs)ms)")
            } catch {
                Log.warn("SentimentGuard: rephrase failed: \(error)")
            }
        }
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

// MARK: - SwiftUI popup

private struct SentimentGuardPopup: View {
    let text: String
    let label: String
    let tone: String
    let onDismiss: () -> Void
    let onApprove: () -> Void
    let onRephrase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(toneColor)
                Text("This reads as ")
                    .font(.system(.callout))
                  + Text(label)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(toneColor)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            Text(preview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            HStack {
                Button("Looks fine", action: onApprove)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Spacer()
                Button {
                    onRephrase()
                } label: {
                    Label("Rephrase via Gemma 4", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360, height: 170)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(toneColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var toneColor: Color {
        sentimentRuleColor(tone)
    }

    private var preview: String {
        let truncated = text.prefix(180)
        return text.count > 180 ? "\(truncated)…" : String(truncated)
    }
}

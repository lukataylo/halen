import AppKit
import SwiftUI
import ApplicationServices

/// Personal style guide — a pure rule engine, no inference. Holds the user's
/// banned-term → preferred-term pairs and "never use X" prohibitions; scans
/// each settled paragraph and surfaces matches in the shared `FindingsPopover`
/// with one-tap replacements.
///
/// The store is plugin-owned but kept deliberately simple so a later phase can
/// also feed its rules into Email Reply / rewrite prompts ("follow these style
/// rules: …").
@MainActor
final class StyleGuide: HalenPlugin {
    let id = "com.halen.style-guide"
    let name = "Personal Style Guide"
    let summary = "Flags your banned words and offers your preferred terms."
    let icon = "character.book.closed"
    let category: PluginCategory = .writing

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?
    let store: StyleRulesStore
    /// Settle-debounce + paragraph extraction + dedup. The `classify` closure
    /// here is synchronous work (a rule scan), not a model call.
    private let classifier = ParagraphClassifier(minLength: 12, settleDelay: 1.5)

    private var task: Task<Void, Never>?
    private var lastCaretRect: CGRect?
    private var activePanel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
        let dir = services.storageDirectory(for: "com.halen.style-guide")
        self.store = StyleRulesStore(fileURL: dir.appending(path: "rules.json"))
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
                    self.classifier.schedule(
                        text: p.text, caretOffset: p.caretOffset,
                        eligibility: { [weak self] _ in
                            !(self?.store.enabledRules.isEmpty ?? true)
                        },
                        classify: { [weak self] paragraph in
                            self?.scan(paragraph: paragraph)
                        }
                    )
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
        AnyView(StyleGuideDetailView(store: store))
    }

    // MARK: - Scan

    private func scan(paragraph: String) {
        let matches = store.scan(paragraph)
        guard !matches.isEmpty else { return }
        let anchor = CaretAnchoredPanel.resolveAnchor(
            caretObserver: caretObserver, cachedCaretRect: lastCaretRect)
        showPopup(matches: matches, anchor: anchor)
    }

    private func showPopup(matches: [StyleMatch], anchor: CaretAnchoredPanel.Anchor?) {
        activePanel?.orderOut(nil)
        dismissTask?.cancel()

        let findings = matches.map { match -> Finding in
            let rule = match.rule
            // A replacement rule gets a one-tap fix; a pure prohibition is
            // informational (there's no preferred term to swap in).
            if rule.isProhibition {
                return Finding(id: rule.id,
                               title: "“\(match.matchedText)”",
                               detail: "Your style guide says: avoid this term.",
                               colorName: "red")
            }
            return Finding(id: rule.id,
                           title: "“\(match.matchedText)” → “\(rule.preferred)”",
                           detail: rule.kind == .regex ? "Your preferred term (regex)." : "Your preferred term.",
                           colorName: "purple",
                           fixLabel: "Replace",
                           onFix: { [weak self] in
                               self?.replace(rule: rule)
                           })
        }
        let size = CGSize(width: 360, height: CGFloat(min(340, 130 + matches.count * 48)))
        let panel = HalenFloatingPanel.make(
            size: NSSize(width: size.width, height: size.height),
            level: .floating, interactive: true, shadow: true)

        let view = FindingsPopover(
            icon: "character.book.closed",
            headline: matches.count == 1 ? "1 style note" : "\(matches.count) style notes",
            headlineColorName: "purple",
            findings: findings,
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

    /// Replace the first match of `rule.banned` in the focused field with
    /// `rule.preferred`. Re-reads the live field text so the replacement
    /// lands even if the user kept typing after the scan. Literal rules
    /// honour word boundaries; regex rules honour their own pattern.
    private func replace(rule: StyleRule) {
        guard let element = caretObserver?.currentElement,
              let current = axReadString(element, kAXValueAttribute) else { return }
        let ns = current as NSString
        let range: NSRange?
        switch rule.kind {
        case .literal: range = StyleRulesStore.wordRange(of: rule.banned, in: ns)
        case .regex:   range = StyleRulesStore.firstRegexMatch(pattern: rule.banned, in: ns)
        }
        guard let range else {
            Log.info("StyleGuide: \"\(rule.banned)\" no longer in field — skipping replace")
            return
        }
        // VoiceOver bridge — describe the substitution so VO users hear
        // the style-guide fix happen at their caret. Brief clause only.
        let announcement = "Replaced '\(rule.banned)' with '\(rule.preferred)'"
        let wrote = caretObserver?.replaceRange(range, with: rule.preferred,
                                                in: element,
                                                describedAs: announcement) ?? false
        Log.info("StyleGuide: replaced \"\(rule.banned)\" → \"\(rule.preferred)\" wrote=\(wrote)")
    }
}

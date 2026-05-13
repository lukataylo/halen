import AppKit
import SwiftUI
import CryptoKit
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
    let rulesStore: SentimentRulesStore
    private var task: Task<Void, Never>?

    /// Hashes we've already classified this session (any label). Avoids re-running
    /// Gemma on the same text every time the user pauses.
    private var classifiedHashes: [String: String] = [:]
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
                case .caretMoved(let p):
                    self.lastCaretRect = CGRect(x: p.rect.x, y: p.rect.y, width: p.rect.width, height: p.rect.height)
                case .textPaused(let p):
                    await self.evaluate(text: p.text, caretOffset: p.caretOffset)
                default:
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        dismissTask?.cancel()
        activePanel?.orderOut(nil)
        activePanel = nil
    }

    // MARK: - Evaluation

    private func evaluate(text: String, caretOffset: Int) async {
        guard text.count > 60 else { return }
        guard text.contains(where: { $0 == "." || $0 == "?" || $0 == "!" }) else { return }

        // Window further down for the prompt. CaretObserver already caps at 8k;
        // this trims to ~800 chars centred on the caret for fast classification.
        let (windowed, _) = windowAroundCaret(text: text, offset: caretOffset, radius: 400)
        guard windowed.count > 40 else { return }

        let hash = sha256Hex(windowed)
        if approvedHashes.contains(hash) { return }
        if classifiedHashes[hash] != nil { return }

        let enabled = rulesStore.enabledRules
        guard !enabled.isEmpty else { return }

        let categoriesBlock = enabled
            .map { "- \($0.label.lowercased()): \($0.prompt)" }
            .joined(separator: "\n")
        let prompt = """
        You are a tone classifier. Categorise the tone of the following text as one of these labels:
        \(categoriesBlock)
        - neutral: the text doesn't strongly match any of the above

        Reply with ONLY the matching label, lowercase, no punctuation, no preamble.

        Text: \"\"\"\(windowed)\"\"\"
        """

        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 16, temperature: 0.1)

        do {
            let response = try await services.inference.complete(request)
            let label = normalizeLabel(response.text)
            classifiedHashes[hash] = label
            Log.info("SentimentGuard: \(label) (\(response.latencyMs)ms)")

            if let matched = enabled.first(where: { $0.label.lowercased() == label }) {
                showPopup(text: windowed, rule: matched, hash: hash)
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

    private func showPopup(text: String, rule: SentimentRule, hash: String) {
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
            onDismiss: { [weak self] in self?.closePanel() },
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

        // Anchor near the caret if we have a recent rect; else bottom-right of main screen.
        let frame: NSRect
        if let caret = lastCaretRect, caret.width > 0 || caret.height > 0 {
            let x = max(20, caret.minX)
            let y = max(20, caret.minY - 195)
            frame = NSRect(x: x, y: y, width: 360, height: 170)
        } else if let screen = NSScreen.main {
            frame = NSRect(x: screen.frame.maxX - 380, y: 80, width: 360, height: 170)
        } else {
            frame = NSRect(x: 200, y: 200, width: 360, height: 170)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        activePanel = panel

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled {
                self?.closePanel()
            }
        }
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

    private func rephrase(originalText: String) {
        Task { @MainActor [services] in
            let prompt = """
            Rewrite the following message in a calmer, more constructive tone while keeping the original intent and length. Output only the rewritten text — no quotes, no preamble.

            Message: \"\"\"\(originalText)\"\"\"
            """
            let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 400, temperature: 0.5)
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

    private func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

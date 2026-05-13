import Foundation
import SwiftUI

/// Watches `text.pause` events and does two things:
///   1. **Learn** — diff the snapshot against the previous one in the same app.
///      Direct substitutions and delete-then-retype patterns are both recognised
///      as corrections.
///   2. **Apply** — when the user types a separator after a known typo, replace
///      it via AX write-back.
///
/// Self-edits (corrections we just wrote) are suppressed in a 3s window. Reverts
/// (user undoing an auto-fix within 60s) demote the dictionary entry — the safety
/// net for context-dependent corrections.
@MainActor
final class TypoFixer: HalenPlugin {
    let id = "com.halen.typo-fixer"
    let name = "Typo Fixer"
    let summary = "Auto-replaces your known typos and learns new corrections as you make them."
    let icon = "character.cursor.ibeam"
    let category: PluginCategory = .writing

    private let eventBus: EventBus
    private let store: TypoStore
    private weak var caretObserver: CaretObserver?
    private var task: Task<Void, Never>?

    private var lastSnapshot: [String: NSString] = [:]

    private struct PendingDeletion {
        let deletedWord: String
        let position: Int
        let timestamp: Date
    }
    private var pendingDeletions: [String: PendingDeletion] = [:]

    private struct SelfEdit {
        let typo: String
        let correction: String
        let timestamp: Date
    }
    private var recentSelfEdits: [SelfEdit] = []
    private var recentAutoFixes: [SelfEdit] = []

    init(services: HalenServices, store: TypoStore) {
        self.eventBus = services.eventBus
        self.store = store
        self.caretObserver = services.caretObserver
    }

    func makeDetailView() -> AnyView {
        AnyView(TypoFixerDetailView(store: store))
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .textPaused(let p):
                    self.handle(text: p.text, caretOffset: p.caretOffset, app: p.appBundleId)
                case .appFocused(let p):
                    self.lastSnapshot.removeValue(forKey: p.appBundleId)
                    self.pendingDeletions.removeValue(forKey: p.appBundleId)
                default:
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        lastSnapshot.removeAll()
        pendingDeletions.removeAll()
    }

    private func handle(text: String, caretOffset: Int, app: String) {
        let ns = text as NSString
        defer { lastSnapshot[app] = ns }

        if let previous = lastSnapshot[app] {
            learn(app: app, old: previous, new: ns)
        }

        applyKnownCorrection(text: ns, caretOffset: caretOffset)
    }

    // MARK: - Learning

    private func learn(app: String, old: NSString, new: NSString) {
        guard let diff = computeDiff(old: old, new: new) else { return }

        if diff.isSubstitution {
            tryRecordCorrection(typo: diff.oldText, correction: diff.newText)
            pendingDeletions.removeValue(forKey: app)
            return
        }

        if diff.isPureDeletion, looksLikeWord(diff.oldText) {
            pendingDeletions[app] = PendingDeletion(
                deletedWord: diff.oldText,
                position: diff.positionInOld,
                timestamp: Date()
            )
            return
        }

        if diff.isPureInsertion, looksLikeWord(diff.newText),
           let pending = pendingDeletions[app],
           Date().timeIntervalSince(pending.timestamp) < 30,
           diff.positionInNew == pending.position {
            tryRecordCorrection(typo: pending.deletedWord, correction: diff.newText)
            pendingDeletions.removeValue(forKey: app)
        }
    }

    private func tryRecordCorrection(typo: String, correction: String) {
        guard looksLikeWord(typo), looksLikeWord(correction) else { return }
        guard typo.lowercased() != correction.lowercased() else { return }
        guard abs(typo.count - correction.count) <= 3 else { return }

        let distance = levenshtein(typo.lowercased(), correction.lowercased())
        guard distance > 0, distance <= 3 else { return }

        let now = Date()

        recentSelfEdits.removeAll { now.timeIntervalSince($0.timestamp) > 3 }
        if recentSelfEdits.contains(where: {
            $0.typo.lowercased() == typo.lowercased() && $0.correction == correction
        }) {
            return
        }

        recentAutoFixes.removeAll { now.timeIntervalSince($0.timestamp) > 60 }
        if let idx = recentAutoFixes.firstIndex(where: {
            $0.typo.lowercased() == correction.lowercased() &&
            $0.correction.lowercased() == typo.lowercased()
        }) {
            let reverted = recentAutoFixes[idx]
            Log.info("TypoFixer: user reverted auto-fix \"\(reverted.typo)\" → \"\(reverted.correction)\" — demoting entry")
            store.demote(typo: reverted.typo)
            recentAutoFixes.remove(at: idx)
            return
        }

        Log.info("TypoFixer learned: \"\(typo)\" → \"\(correction)\" (dist=\(distance))")
        store.observe(typo: typo, correction: correction)
    }

    // MARK: - Applying

    private func applyKnownCorrection(text ns: NSString, caretOffset: Int) {
        let length = ns.length
        guard caretOffset > 0, caretOffset <= length else { return }

        guard let last = character(ns, at: caretOffset - 1),
              last.isWhitespace || last.isPunctuation else {
            return
        }

        var end = caretOffset - 1
        while end > 0, let ch = character(ns, at: end - 1),
              ch.isWhitespace || ch.isPunctuation {
            end -= 1
        }
        var start = end
        while start > 0, let ch = character(ns, at: start - 1),
              !ch.isWhitespace, !ch.isPunctuation {
            start -= 1
        }
        guard start < end else { return }

        let word = ns.substring(with: NSRange(location: start, length: end - start))
        guard let correction = store.activeCorrection(for: word) else { return }
        let cased = matchCase(of: word, in: correction)

        let range = NSRange(location: start, length: end - start)
        Log.info("TypoFixer applied: \"\(word)\" → \"\(cased)\"")

        let now = Date()
        recentSelfEdits.append(SelfEdit(typo: word, correction: cased, timestamp: now))
        recentAutoFixes.append(SelfEdit(typo: word, correction: cased, timestamp: now))
        caretObserver?.replaceRange(range, with: cased)
    }

    private func character(_ ns: NSString, at index: Int) -> Character? {
        guard index >= 0, index < ns.length else { return nil }
        guard let scalar = Unicode.Scalar(ns.character(at: index)) else { return nil }
        return Character(scalar)
    }

    private func matchCase(of source: String, in replacement: String) -> String {
        guard let first = source.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}

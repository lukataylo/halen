import Foundation

/// Watches `text.pause` events. Two responsibilities, one module so the two are easy to
/// coordinate (self-edit suppression):
///
///   1. **Learn**: when the diff between consecutive snapshots in the same app looks
///      like the user just corrected one word for another, record it in `TypoStore`.
///      After two observations of the same `typo → correction` pair, the correction
///      becomes active.
///   2. **Apply**: when the user just typed a separator after a word that's in the
///      store's active set, replace the word via AX write-back.
///
/// Multi-step corrections (delete-then-retype, with a pause in between) are handled by
/// tracking pending deletions per-app and pairing them with subsequent insertions at the
/// same position within a 30s window.
@MainActor
final class TypoFixer {
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

    /// Two windows tracking our own writes:
    ///
    ///   - `recentSelfEdits` (3s): suppresses the immediate "we just wrote X→Y, the
    ///     resulting text.pause is our doing" false learning signal.
    ///   - `recentAutoFixes` (60s): when the user backspaces and retypes our
    ///     correction back to the original within this window, treat it as a revert
    ///     and `demote()` the dictionary entry — particularly important for
    ///     context-dependent entries like form↔from where the auto-fix is sometimes
    ///     wrong and the user shouldn't have to suffer it twice.
    private struct SelfEdit {
        let typo: String
        let correction: String
        let timestamp: Date
    }
    private var recentSelfEdits: [SelfEdit] = []
    private var recentAutoFixes: [SelfEdit] = []

    init(eventBus: EventBus, store: TypoStore, caretObserver: CaretObserver) {
        self.eventBus = eventBus
        self.store = store
        self.caretObserver = caretObserver
    }

    func start() {
        task = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .textPaused(let p):
                    self.handle(text: p.text, caretOffset: p.caretOffset, app: p.appBundleId)
                case .appFocused(let p):
                    // Reset per-app state so cross-app focus changes don't produce phantom diffs.
                    self.lastSnapshot.removeValue(forKey: p.appBundleId)
                    self.pendingDeletions.removeValue(forKey: p.appBundleId)
                default:
                    break
                }
            }
        }
    }

    func stop() { task?.cancel() }

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

        // Don't relearn from our own writes (3s window).
        recentSelfEdits.removeAll { now.timeIntervalSince($0.timestamp) > 3 }
        if recentSelfEdits.contains(where: {
            $0.typo.lowercased() == typo.lowercased() && $0.correction == correction
        }) {
            return
        }

        // Revert detection (60s window): if the user just undid an auto-fix we made,
        // demote the dictionary entry rather than recording a (wrong) new correction
        // in the opposite direction.
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

    // MARK: - Applying known corrections

    private func applyKnownCorrection(text ns: NSString, caretOffset: Int) {
        let length = ns.length
        guard caretOffset > 0, caretOffset <= length else { return }

        // Trigger only when the character just before the caret is a separator.
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

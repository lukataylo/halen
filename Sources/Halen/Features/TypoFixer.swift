import Foundation

/// Demo feature for M1 verification: when `text.pause` fires and the user just typed
/// a whitespace or punctuation character right after a known typo, replace the typo
/// with its correction via AX write-back.
///
/// This is intentionally a static dictionary, not a model. M2 swaps the dictionary
/// for an Ollama / Gemma 4 call but keeps the same trigger / replace plumbing.
@MainActor
final class TypoFixer {
    private let eventBus: EventBus
    private weak var caretObserver: CaretObserver?
    private var task: Task<Void, Never>?

    /// Lowercase typo → replacement. Case is preserved when the typo started with a capital.
    private let dictionary: [String: String] = [
        "teh": "the",
        "wnat": "want",
        "adn": "and",
        "recieve": "receive",
        "seperate": "separate",
        "definately": "definitely",
        "occured": "occurred",
        "thier": "their",
        "alot": "a lot",
        "halendemo": "HALEN AUTO-REPLACE WORKING",
    ]

    init(eventBus: EventBus, caretObserver: CaretObserver) {
        self.eventBus = eventBus
        self.caretObserver = caretObserver
    }

    func start() {
        task = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                if case .textPaused(let p) = event {
                    self.tryFix(text: p.text, caretOffset: p.caretOffset)
                }
            }
        }
    }

    func stop() { task?.cancel() }

    private func tryFix(text: String, caretOffset: Int) {
        let ns = text as NSString
        let length = ns.length
        guard caretOffset > 0, caretOffset <= length else { return }

        // Trigger only when the char just before the caret is a separator
        // (whitespace or punctuation). That's the canonical "user just finished
        // typing a word" signal, same as iOS / Grammarly.
        guard let lastChar = character(in: ns, at: caretOffset - 1),
              lastChar.isWhitespace || lastChar.isPunctuation else {
            return
        }

        // Walk back over the separator(s) to the end of the previous word.
        var end = caretOffset - 1
        while end > 0, let ch = character(in: ns, at: end - 1),
              ch.isWhitespace || ch.isPunctuation {
            end -= 1
        }
        // Then walk back over word characters to find its start.
        var start = end
        while start > 0, let ch = character(in: ns, at: start - 1),
              !ch.isWhitespace, !ch.isPunctuation {
            start -= 1
        }
        guard start < end else { return }

        let word = ns.substring(with: NSRange(location: start, length: end - start))
        guard let replacement = dictionary[word.lowercased()] else { return }

        let cased = matchCase(of: word, in: replacement)
        let range = NSRange(location: start, length: end - start)

        Log.info("TypoFixer: \"\(word)\" → \"\(cased)\" at \(NSStringFromRange(range))")
        caretObserver?.replaceRange(range, with: cased)
    }

    private func character(in ns: NSString, at index: Int) -> Character? {
        guard index >= 0, index < ns.length else { return nil }
        let code = ns.character(at: index)
        guard let scalar = Unicode.Scalar(code) else { return nil }
        return Character(scalar)
    }

    private func matchCase(of source: String, in replacement: String) -> String {
        guard let first = source.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}

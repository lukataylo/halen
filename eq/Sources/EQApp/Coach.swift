import EQCore
import Foundation
import FoundationModels

/// Turns a session's numbers into one takeaway and one thing to try, on-device
/// via Apple's Foundation Models. The model never measures anything — it only
/// phrases what the signal processing already found.
struct Coach {
    @Generable
    struct Takeaway {
        @Guide(description: "One sentence, second person, naming the single most useful observation. Warm and specific, never judgemental.")
        var observation: String
        @Guide(description: "One concrete thing to try in the next conversation, under 15 words.")
        var nextTime: String
    }

    func takeaway(for r: SessionRecord) async -> String {
        guard case .available = SystemLanguageModel.default.availability else { return fallback(r) }
        let card = r.effectiveScores
        let notable = card.all.flatMap(\.factors)
            .filter { !r.disputed.contains($0.id) && $0.penalty > 0.3 }
            .sorted { $0.penalty > $1.penalty }
            .prefix(3)
            .map { "- \($0.label): \($0.detail)" }
            .joined(separator: "\n")
        let prompt = """
        You are a calm, kind communication coach. These measurements describe only how the user spoke \
        in a \(r.minutes)-minute conversation (\(r.title)). Pace, fillers and \
        vocal variety are compared with common targets; heated moments are compared with the user's own calm voice. \
        Do not invent facts beyond them, and don't mention numeric scores.

        Presence \(show(card.presence)), Clarity \(show(card.clarity)), Composure \(show(card.composure)).
        What stood out:
        \(notable.isEmpty ? "- Nothing was notably off target." : notable)
        """
        do {
            let out = try await LanguageModelSession().respond(to: prompt, generating: Takeaway.self)
            return "\(out.content.observation) Next time: \(out.content.nextTime)"
        } catch {
            return fallback(r)
        }
    }

    private func show(_ s: Score) -> String { s.value.map(String.init) ?? "not enough data" }

    /// Template copy for Macs without Apple Intelligence — still one
    /// observation and one thing to try, like the model's version.
    private func fallback(_ r: SessionRecord) -> String {
        let worst = r.effectiveScores.all.flatMap(\.factors).filter { !r.disputed.contains($0.id) }.max { $0.penalty < $1.penalty }
        guard let worst, worst.penalty > 0.5 else { return "A steady conversation. Nothing stood out." }
        return "\(worst.label) stood out: \(worst.detail.lowercased()). Next time: \(Self.tips[worst.id] ?? "pick one moment to slow down.")"
    }

    static let tips: [String: String] = [
        "talk": "after your main point, ask what they think.",
        "interrupt": "let them finish, then count one beat before you reply.",
        "monologue": "stop after your main point and check in.",
        "pace": "take one breath before each answer.",
        "fillers": "when you reach for \"um\", pause instead.",
        "variety": "lean on the one word that matters in each sentence.",
        "spikes": "when you feel it rising, pause before you reply.",
        "drift": "check in with yourself halfway through long calls.",
    ]
}

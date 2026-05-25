import Foundation

/// The character's facial expression. The plugin (`plugin.py`) drives these
/// via NDJSON messages — tone classification, "thinking" while we wait for
/// inference, "neutral" by default. They map to emoji + a tint colour in
/// `BuddyView`.
enum Expression: String, Codable {
    case neutral
    case happy
    case worried
    case thinking
}

/// The bubble's current job. `chat` collects a free-form question; `rewrite`
/// expects an instruction that gets applied to whatever the focused app has
/// selected (handled host-side via `ax/replaceRange`).
enum InputMode: String, Codable {
    case chat
    case rewrite

    var placeholder: String {
        switch self {
        case .chat: return "Ask me anything…"
        case .rewrite: return "How should I rewrite the selection?"
        }
    }

    var heading: String {
        switch self {
        case .chat: return "Ask Halen"
        case .rewrite: return "Rewrite selection"
        }
    }
}

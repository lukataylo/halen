import Foundation

/// Events emitted by the host and consumed by features (typo-fixer, tone-logger, …).
///
/// Each case is named to match its future JSON-RPC method (`text.pause`, `caret.moved`, …)
/// and each payload is `Codable` so the M4 extraction to out-of-process plugins is mechanical
/// — the case maps to a method, the payload maps to `params`.
enum Event: Sendable {
    case textPaused(TextPaused)
    case textSaved(TextSaved)
    case caretMoved(CaretMoved)
    case appFocused(AppFocused)
    case clipboardChanged(ClipboardChanged)

    var method: String {
        switch self {
        case .textPaused:       return "text.pause"
        case .textSaved:        return "text.save"
        case .caretMoved:       return "caret.moved"
        case .appFocused:       return "app.focused"
        case .clipboardChanged: return "clipboard.changed"
        }
    }

    struct TextPaused: Sendable, Codable {
        let appBundleId: String
        let appName: String
        let text: String
        let caretOffset: Int
        let timestamp: Date
    }

    struct TextSaved: Sendable, Codable {
        let appBundleId: String
        let appName: String
        let text: String
        let timestamp: Date
    }

    struct CaretMoved: Sendable, Codable {
        let appBundleId: String
        let rect: CaretRect
        let timestamp: Date
    }

    struct AppFocused: Sendable, Codable {
        let appBundleId: String
        let appName: String
        let timestamp: Date
    }

    struct ClipboardChanged: Sendable, Codable {
        let textPreview: String
        let timestamp: Date
    }

    struct CaretRect: Sendable, Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}

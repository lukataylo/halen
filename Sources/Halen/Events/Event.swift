import Foundation

/// Events emitted by the host and consumed by features (typo-fixer, tone-logger, …).
///
/// Each case is named to match its future JSON-RPC method (`text.pause`, `caret.moved`, …)
/// and each payload is `Codable` so the M4 extraction to out-of-process plugins is mechanical
/// — the case maps to a method, the payload maps to `params`.
enum Event: Sendable {
    case textPaused(TextPaused)
    case caretMoved(CaretMoved)
    case appFocused(AppFocused)
    case inferenceActivity(InferenceActivity)

    var method: String {
        switch self {
        case .textPaused:        return "text.pause"
        case .caretMoved:        return "caret.moved"
        case .appFocused:        return "app.focused"
        case .inferenceActivity: return "inference.activity"
        }
    }

    struct TextPaused: Sendable, Codable {
        let appBundleId: String
        let appName: String
        let text: String
        let caretOffset: Int
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

    /// A plugin is running (or has finished) an async Gemma call. Lets the
    /// caret overlay show a "working" state so the user knows something is
    /// happening during the multi-second wait. Generic on purpose — any
    /// Gemma-backed feature can publish it, keyed by `source`.
    struct InferenceActivity: Sendable, Codable {
        enum Phase: String, Sendable, Codable { case started, finished }
        let phase: Phase
        let source: String        // e.g. "snippet-expander" — for logs
        /// On-screen anchor for the work (e.g. the placeholder the result will
        /// land in). When set, the overlay shows its busy state here instead of
        /// at the last-known caret. nil for sources with no text anchor.
        var anchor: CaretRect? = nil
        let timestamp: Date
    }

    struct CaretRect: Sendable, Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}

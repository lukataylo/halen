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
    case findingDetected(FindingDetected)
    case findingsCleared(FindingsCleared)

    var method: String {
        switch self {
        case .textPaused:        return "text.pause"
        case .caretMoved:        return "caret.moved"
        case .appFocused:        return "app.focused"
        case .inferenceActivity: return "inference.activity"
        case .findingDetected:   return "finding.detected"
        case .findingsCleared:   return "findings.cleared"
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

    /// A plugin (SentimentGuard, ClarityChecker, StyleGuide, …) has just
    /// classified some text and wants to surface a finding. The host's
    /// `OverlayController` consumes these to tint the Halen caret indicator
    /// by severity and to back the hover popover.
    ///
    /// Plugins emit one `.findingDetected` per classification result; on the
    /// next text.pause they'll either emit another (replacing the previous
    /// for the same source) or stay silent (the paragraph is clean). When the
    /// user moves the caret outside the flagged paragraph the host clears
    /// them locally; plugins can also force-clear via `.findingsCleared`.
    struct FindingDetected: Sendable, Codable {
        /// Visual severity bucket. Highest-severity finding wins the
        /// indicator tint when multiple are active.
        enum Severity: String, Sendable, Codable, Comparable {
            case clarity        // yellow — passive voice, vague pronouns, …
            case conciseness    // orange — wordy / filler phrasing
            case tone           // red — hostile, irritated, …

            /// Strict ranking — `.tone` outranks `.conciseness` outranks
            /// `.clarity` when several findings collide on the same paragraph.
            private var rank: Int {
                switch self {
                case .clarity:     return 0
                case .conciseness: return 1
                case .tone:        return 2
                }
            }
            static func < (lhs: Severity, rhs: Severity) -> Bool {
                lhs.rank < rhs.rank
            }
        }

        /// Stable identifier — `<source>:<paragraphHash>`. Replacing a finding
        /// with a new one from the same source+paragraph is a no-op for the UI.
        let id: String
        /// Plugin id of the emitter, e.g. `com.halen.sentiment-guard`.
        let source: String
        let severity: Severity
        /// One-line headline shown in the hover popover, e.g. "Reads as Irritated".
        let summary: String
        /// Where the flagged text lives on screen — used to anchor the hover
        /// popover and to detect when the caret has moved away.
        let anchor: CaretRect
        /// SHA-256 of the paragraph the finding pertains to. The host uses
        /// this to dedup repeat emissions of the same finding.
        let paragraphHash: String
        /// App the finding originated in. The host clears all findings for
        /// the previous app on `.appFocused` so stale tints don't outlive
        /// their context.
        let appBundleId: String
        let timestamp: Date
    }

    /// Plugin-driven clear (e.g. user approved a finding, or the plugin was
    /// disabled mid-flight). The host removes any active finding matching
    /// `id`, or all findings from `source` when `id` is nil.
    struct FindingsCleared: Sendable, Codable {
        let source: String
        let id: String?
        let timestamp: Date
    }
}

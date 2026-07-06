import Foundation

/// Events emitted by the host and consumed by features (typo-fixer, tone-logger, …).
///
/// Each case is named to match its future JSON-RPC method (`text.pause`, `caret.moved`, …)
/// and each payload is `Codable` so the M4 extraction to out-of-process plugins is mechanical
/// — the case maps to a method, the payload maps to `params`.
public enum Event: Sendable {
    case textPaused(TextPaused)
    case caretMoved(CaretMoved)
    case appFocused(AppFocused)
    case inferenceActivity(InferenceActivity)
    case findingDetected(FindingDetected)
    case findingsCleared(FindingsCleared)
    case findingActionRequested(FindingActionRequested)

    public var method: String {
        switch self {
        case .textPaused:              return "text.pause"
        case .caretMoved:              return "caret.moved"
        case .appFocused:              return "app.focused"
        case .inferenceActivity:       return "inference.activity"
        case .findingDetected:         return "finding.detected"
        case .findingsCleared:         return "findings.cleared"
        case .findingActionRequested:  return "finding.action"
        }
    }

    public struct TextPaused: Sendable, Codable {
        public let appBundleId: String
        public let appName: String
        public let text: String
        public let caretOffset: Int
        public let timestamp: Date

        public init(appBundleId: String, appName: String, text: String,
                    caretOffset: Int, timestamp: Date) {
            self.appBundleId = appBundleId
            self.appName = appName
            self.text = text
            self.caretOffset = caretOffset
            self.timestamp = timestamp
        }
    }

    public struct CaretMoved: Sendable, Codable {
        public let appBundleId: String
        public let rect: CaretRect
        public let timestamp: Date

        public init(appBundleId: String, rect: CaretRect, timestamp: Date) {
            self.appBundleId = appBundleId
            self.rect = rect
            self.timestamp = timestamp
        }
    }

    public struct AppFocused: Sendable, Codable {
        public let appBundleId: String
        public let appName: String
        public let timestamp: Date

        public init(appBundleId: String, appName: String, timestamp: Date) {
            self.appBundleId = appBundleId
            self.appName = appName
            self.timestamp = timestamp
        }
    }

    /// A plugin is running (or has finished) an async Gemma call. Lets the
    /// caret overlay show a "working" state so the user knows something is
    /// happening during the multi-second wait. Generic on purpose — any
    /// Gemma-backed feature can publish it, keyed by `source`.
    public struct InferenceActivity: Sendable, Codable {
        public enum Phase: String, Sendable, Codable { case started, finished }
        public let phase: Phase
        public let source: String        // e.g. "snippet-expander" — for logs
        /// On-screen anchor for the work (e.g. the placeholder the result will
        /// land in). When set, the overlay shows its busy state here instead of
        /// at the last-known caret. nil for sources with no text anchor.
        public var anchor: CaretRect? = nil
        public let timestamp: Date

        public init(phase: Phase, source: String, anchor: CaretRect? = nil,
                    timestamp: Date) {
            self.phase = phase
            self.source = source
            self.anchor = anchor
            self.timestamp = timestamp
        }
    }

    public struct CaretRect: Sendable, Codable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
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
    public struct FindingDetected: Sendable, Codable {
        /// Visual severity bucket. Highest-severity finding wins the
        /// indicator tint when multiple are active.
        public enum Severity: String, Sendable, Codable, Comparable {
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
            public static func < (lhs: Severity, rhs: Severity) -> Bool {
                lhs.rank < rhs.rank
            }
        }

        /// Stable identifier — `<source>:<paragraphHash>`. Replacing a finding
        /// with a new one from the same source+paragraph is a no-op for the UI.
        public let id: String
        /// Plugin id of the emitter, e.g. `com.halen.writing-assistant`.
        public let source: String
        public let severity: Severity
        /// One-line headline shown in the hover popover, e.g. "Reads as Irritated".
        public let summary: String
        /// Where the flagged text lives on screen — used to anchor the hover
        /// popover and to detect when the caret has moved away.
        public let anchor: CaretRect
        /// SHA-256 of the paragraph the finding pertains to. The host uses
        /// this to dedup repeat emissions of the same finding.
        public let paragraphHash: String
        /// App the finding originated in. The host clears all findings for
        /// the previous app on `.appFocused` so stale tints don't outlive
        /// their context.
        public let appBundleId: String
        public let timestamp: Date

        public init(id: String, source: String, severity: Severity,
                    summary: String, anchor: CaretRect, paragraphHash: String,
                    appBundleId: String, timestamp: Date) {
            self.id = id
            self.source = source
            self.severity = severity
            self.summary = summary
            self.anchor = anchor
            self.paragraphHash = paragraphHash
            self.appBundleId = appBundleId
            self.timestamp = timestamp
        }
    }

    /// Plugin-driven clear (e.g. user approved a finding, or the plugin was
    /// disabled mid-flight). The host removes any active finding matching
    /// `id`, or all findings from `source` when `id` is nil.
    public struct FindingsCleared: Sendable, Codable {
        public let source: String
        public let id: String?
        public let timestamp: Date

        public init(source: String, id: String?, timestamp: Date) {
            self.source = source
            self.id = id
            self.timestamp = timestamp
        }
    }

    /// User-initiated action on an active finding, emitted by the indicator
    /// popover's buttons. The plugin (matching by `source`) subscribes and
    /// does the right thing: `.approve` adds the paragraph to its allowlist
    /// and clears the finding; `.rephrase` runs the plugin's rewrite path
    /// (streaming text into a callout / clipboard). The overlay stays out
    /// of plugin-specific business; it just emits the intent.
    public struct FindingActionRequested: Sendable, Codable {
        public enum Action: String, Sendable, Codable {
            case approve
            case rephrase
        }
        /// Plugin id, matches the `source` of the finding being acted on.
        public let source: String
        /// Finding id (same as in `FindingDetected.id`) so the plugin knows
        /// exactly which paragraph the user clicked through.
        public let findingId: String
        public let action: Action
        public let timestamp: Date

        public init(source: String, findingId: String, action: Action,
                    timestamp: Date) {
            self.source = source
            self.findingId = findingId
            self.action = action
            self.timestamp = timestamp
        }
    }
}

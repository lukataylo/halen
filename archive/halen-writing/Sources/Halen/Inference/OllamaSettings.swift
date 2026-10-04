import Foundation

/// User-configurable Ollama endpoint. Lives in UserDefaults so the Settings
/// UI can drive it via `@AppStorage` and the OllamaBackend can re-read it
/// without needing a settings injection or restart.
///
/// Why not put this in `InferenceSettings`? `InferenceSettings` is `@MainActor`
/// and `@Observable` — that's the right shape for SwiftUI bindings on
/// preference *order*. Ollama's endpoint URL is read from a non-isolated
/// backend (`OllamaBackend.availability()` runs on the router actor, not
/// MainActor), so we keep it as a plain UserDefaults-backed enum to avoid
/// the cross-actor hop on every inference call.
enum OllamaSettings {
    static let baseURLKey = "halen.inference.ollamaBaseURL"

    /// Default endpoint — matches Ollama's documented localhost default
    /// (`OLLAMA_HOST=127.0.0.1:11434` is what `ollama serve` listens on
    /// out of the box). Force-unwrap is safe; the literal is a known-good
    /// constant. `nonisolated` so backend code (non-MainActor) can read it.
    nonisolated static let defaultBaseURLString = "http://localhost:11434"

    nonisolated static var defaultBaseURL: URL {
        URL(string: defaultBaseURLString)!
    }

    /// The configured endpoint, validated. Falls back to the default if the
    /// stored value is missing, empty, or fails validation — the backend's
    /// contract is "always return a URL that's at least syntactically usable."
    /// Read on every backend call so a Settings change takes effect without
    /// restarting Halen.
    nonisolated static func currentBaseURL() -> URL {
        guard let raw = UserDefaults.standard.string(forKey: baseURLKey),
              !raw.isEmpty,
              let url = validate(raw)
        else { return defaultBaseURL }
        return url
    }

    /// Validate a user-entered URL string. Returns the parsed URL on success
    /// or nil if the string isn't an http/https URL with a non-empty host.
    /// Settings uses this to gate the save button — we never want a
    /// malformed value to land in UserDefaults.
    nonisolated static func validate(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// True iff `url` points at a loopback / link-local address — i.e. a
    /// process running on this Mac. Settings badges non-loopback URLs with
    /// a subtle warning (Halen markets itself as local-first; an SSH-tunneled
    /// or LAN-reachable Ollama violates that promise).
    nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" { return true }
        // 127.0.0.0/8 — every address starting with 127. is loopback per
        // RFC 5735. A literal prefix match covers it without dragging in
        // a full CIDR parser.
        return host.hasPrefix("127.")
    }
}

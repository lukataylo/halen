import Foundation
import Observation

/// The register the user writes in for a given app — Slack reads casual, the
/// company wiki reads formal. Read by Writing Coach (tone + clarity
/// classifiers) and Snippet Expander's email-reply action so a blunt
/// Slack message isn't judged the way a blunt email is.
enum ToneProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case formal
    case businessCasual
    case casual
    case neutral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .formal:         return "Formal"
        case .businessCasual: return "Business casual"
        case .casual:         return "Casual"
        case .neutral:        return "Neutral"
        }
    }

    /// A clause describing the register, dropped into classification / rewrite
    /// prompts so the model judges text against the right bar.
    var promptClause: String {
        switch self {
        case .formal:
            return "The user writes in a formal, professional register in this app; hold the text to a polished, measured standard."
        case .businessCasual:
            return "The user writes in a business-casual register in this app; warm and approachable but still professional — relaxed phrasing is fine as long as it stays courteous and clear."
        case .casual:
            return "The user writes in a casual, relaxed register in this app; brief or blunt phrasing is normal and should not be over-flagged."
        case .neutral:
            return "The user writes in a neutral register in this app."
        }
    }

    /// Whether this profile sets an *expected* register the message can be
    /// checked against. Neutral imposes no target — it's "no preference".
    var enforcesTarget: Bool { self != .neutral }

    /// Ordering of registers by formality, so detection can flag only when a
    /// message is *less* formal than the app expects (a stiff message in a
    /// casual app isn't worth a nag). Higher = more formal.
    var formalityRank: Int {
        switch self {
        case .formal:         return 3
        case .businessCasual: return 2
        case .casual:         return 1
        case .neutral:        return 0
        }
    }

    /// One-line descriptor of the expected register, dropped into the
    /// register-classification prompt so the model knows what each label means.
    /// `nil` for neutral (there's nothing to match against).
    var targetDescriptor: String? {
        switch self {
        case .formal:
            return "formal — polished and professional, complete sentences, no slang or contractions-heavy phrasing"
        case .businessCasual:
            return "business casual — friendly and approachable but still professional; light contractions are fine, but no slang, sloppiness, or bluntness"
        case .casual:
            return "casual — relaxed and conversational, contractions and informal phrasing welcome"
        case .neutral:
            return nil
        }
    }

    /// The lowercase token the register classifier emits for this profile.
    var classifierToken: String {
        switch self {
        case .formal:         return "formal"
        case .businessCasual: return "business-casual"
        case .casual:         return "casual"
        case .neutral:        return "neutral"
        }
    }

    /// Map a register-classifier reply back to a profile, tolerating the
    /// spacing/casing variants a small model produces (and the bare "business"
    /// left when a first-token parse clips "business casual"). Returns nil for
    /// anything that isn't one of the three register labels — crucially
    /// including "neutral" and "informal", so an off-list reply never flags.
    static func fromClassifierToken(_ token: String) -> ToneProfile? {
        switch token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "formal":                                       return .formal
        case "business-casual", "business casual", "businesscasual", "business":
                                                             return .businessCasual
        case "casual":                                       return .casual
        default:                                             return nil
        }
    }
}

/// Host service: per-app tone profiles keyed by bundle id. Owned by the host
/// and exposed through `HalenServices.toneProfiles` so any plugin can read a
/// consistent profile for the app the user is currently in. The editor
/// lives at Settings → App tone profiles (`ToneProfilesDetailView`); every
/// other touch is a read.
@Observable
@MainActor
final class AppToneProfileStore {
    private(set) var profiles: [String: ToneProfile] = [:]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    private static func defaultFileURL() -> URL {
        HalenSupportDirectory
            .subdirectory("com.halen.tone-profiles")
            .appending(path: "profiles.json")
    }

    /// Resolved profile for `bundleId`, defaulting to `.neutral`.
    func profile(for bundleId: String?) -> ToneProfile {
        guard let bundleId else { return .neutral }
        return profiles[bundleId] ?? .neutral
    }

    func setProfile(_ profile: ToneProfile, for bundleId: String) {
        let trimmed = bundleId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if profile == .neutral {
            // Neutral is the default — storing it just bloats the file.
            profiles.removeValue(forKey: trimmed)
        } else {
            profiles[trimmed] = profile
        }
        save()
    }

    func removeProfile(for bundleId: String) {
        guard profiles.removeValue(forKey: bundleId) != nil else { return }
        save()
    }

    /// Assigned profiles sorted by bundle id, for a stable editor list.
    var sortedEntries: [(bundleId: String, profile: ToneProfile)] {
        profiles.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var version: Int
        var profiles: [String: ToneProfile]
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            profiles = payload.profiles
            Log.info("AppToneProfileStore: loaded \(profiles.count) profiles")
        } catch {
            Log.debug("AppToneProfileStore: no existing file")
        }
    }

    private func save() {
        do {
            let payload = Payload(version: 1, profiles: profiles)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("AppToneProfileStore save failed: \(error.localizedDescription)")
        }
    }
}

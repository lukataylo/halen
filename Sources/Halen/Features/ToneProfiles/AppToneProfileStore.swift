import Foundation
import Observation

/// The register the user writes in for a given app — Slack reads casual, the
/// company wiki reads formal. Plugins that classify or rewrite text (Sentiment
/// Guard, Clarity Checker) read this to bias their thresholds and prompts so a
/// blunt Slack message isn't judged the way a blunt email is.
enum ToneProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case formal
    case casual
    case neutral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .formal:  return "Formal"
        case .casual:  return "Casual"
        case .neutral: return "Neutral"
        }
    }

    /// A clause describing the register, dropped into classification / rewrite
    /// prompts so the model judges text against the right bar.
    var promptClause: String {
        switch self {
        case .formal:
            return "The user writes in a formal, professional register in this app; hold the text to a polished, measured standard."
        case .casual:
            return "The user writes in a casual, relaxed register in this app; brief or blunt phrasing is normal and should not be over-flagged."
        case .neutral:
            return "The user writes in a neutral register in this app."
        }
    }
}

/// Host service: per-app tone profiles keyed by bundle id. Owned by the host
/// and exposed through `HalenServices.toneProfiles` so any plugin can read a
/// consistent profile for the app the user is currently in. The Tone Profiles
/// plugin's detail view is the editor; every other touch is a read.
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
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appending(path: "Halen", directoryHint: .isDirectory)
            .appending(path: "com.halen.tone-profiles", directoryHint: .isDirectory)
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

import Foundation

/// Plugins request a tier, not a specific model. The host picks the concrete model
/// based on device capability, user preference, and current load.
///
/// Defaults (May 2026):
///   small  → google/gemma-4-E2B-it  (~2B effective, fast typo/classification path)
///   medium → google/gemma-4-E4B-it  (~4B effective, default for rewrites)
///   large  → google/gemma-4-26B-A4B-it (workstation / optional cloud, heavy reasoning)
enum ModelTier: String, Sendable, Codable {
    case small
    case medium
    case large

    var defaultModelId: String {
        switch self {
        case .small:  return "google/gemma-4-E2B-it"
        case .medium: return "google/gemma-4-E4B-it"
        case .large:  return "google/gemma-4-26B-A4B-it"
        }
    }
}

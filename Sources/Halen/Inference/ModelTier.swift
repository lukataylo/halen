import Foundation

/// Plugins request a tier, not a specific model. The host picks the concrete model
/// based on device capability, user preference, and current load.
///
/// Defaults (May 2026):
///   classifier → Qwen 2.5 0.5B-Instruct  (~500M, dedicated to label/yes-no tasks)
///   small      → google/gemma-4-E2B-it    (~2B effective, fast typo/classification path)
///   medium     → google/gemma-4-E4B-it    (~4B effective, default for rewrites)
///   large      → google/gemma-4-26B-A4B-it (workstation / optional cloud, heavy reasoning)
///
/// The `.classifier` tier exists for the writing-plugin hot path
/// (SentimentGuard, ClarityChecker, StyleGuide). It targets a tiny, very fast
/// model that's good enough at multi-label classification — so paragraph-pause
/// → popover lands in well under 2 s, instead of waiting for the 4 B Gemma.
/// Rewrites/generation stay on `.medium`.
enum ModelTier: String, Sendable, Codable {
    case classifier
    case small
    case medium
    case large

    var defaultModelId: String {
        switch self {
        case .classifier: return "Qwen/Qwen2.5-0.5B-Instruct"
        case .small:      return "google/gemma-4-E2B-it"
        case .medium:     return "google/gemma-4-E4B-it"
        case .large:      return "google/gemma-4-26B-A4B-it"
        }
    }
}

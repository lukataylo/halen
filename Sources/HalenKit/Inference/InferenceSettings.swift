import Foundation
import Observation

/// User-facing inference preferences + live backend status. Owned by
/// `AppCoordinator`, observed by `SettingsView`, and read by
/// `RouterInferenceClient` when ordering candidate backends.
@Observable
@MainActor
final class InferenceSettings {
    static let preferenceOrderKey = "halen.inference.backendOrder"

    /// Backend priority, highest first. Persisted as raw-value strings.
    var preferenceOrder: [BackendKind] {
        didSet { persist() }
    }

    /// Last probed availability per backend — drives the Settings status dots.
    /// Live state, not persisted.
    var availability: [BackendKind: BackendAvailability] = [:]

    init() {
        if let raw = UserDefaults.standard.array(forKey: Self.preferenceOrderKey) as? [String] {
            let restored = raw.compactMap(BackendKind.init(rawValue:))
            // Append any backend kinds added since the order was last saved.
            let missing = BackendKind.allCases.filter { !restored.contains($0) }
            self.preferenceOrder = restored + missing
        } else {
            // Default: Apple Intelligence first (best quality, zero-install when
            // available), then the bundled model (the universal floor), then
            // Ollama (opt-in, but the only backend that serves the large tier).
            self.preferenceOrder = [.appleFoundationModels, .bundledLlama, .ollama]
        }
    }

    private func persist() {
        UserDefaults.standard.set(preferenceOrder.map(\.rawValue), forKey: Self.preferenceOrderKey)
    }
}

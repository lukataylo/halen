import Foundation

/// Mic and far-end levels for the dot waveform, ~6 s of history at 10 Hz.
@MainActor
final class LiveMeter: ObservableObject {
    @Published private(set) var you: [Float] = []
    @Published private(set) var them: [Float]?

    func push(you level: Float, them other: Float?) {
        you = Array((you + [level]).suffix(64))
        if let other { them = Array(((them ?? []) + [other]).suffix(64)) }
    }

    func reset() { you = []; them = nil }
}

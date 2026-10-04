// swift-tools-version: 6.2
import PackageDescription

// Working title "HalenEQ" — a local-only conversation coach that hears only
// your side of a call. See ../docs/EQ_FEATURES.md for the product brief.
let package = Package(
    name: "HalenEQ",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "halen-eq", targets: ["EQApp"]),
        .executable(name: "eq-analyze", targets: ["EQAnalyze"]),
        .library(name: "EQCore", targets: ["EQCore"]),
    ],
    dependencies: [
        // On-device VAD + speaker embeddings (CoreML/ANE) for the voice check.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
        // Sparkle 2 — signed (EdDSA) auto-updates from halen.dev/eq/appcast.xml.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        // Pure signal processing, metrics, scoring, storage. No UI, no models
        // that need downloading — everything here is unit-testable offline.
        .target(name: "EQCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/EQCore"),
        .executableTarget(name: "EQApp", dependencies: ["EQCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/EQApp"),
        // Dev CLI: run the pipeline over an audio file and print the numbers.
        .executableTarget(name: "EQAnalyze", dependencies: ["EQCore"], path: "Sources/EQAnalyze"),
        .testTarget(name: "EQCoreTests", dependencies: ["EQCore"], path: "Tests/EQCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)

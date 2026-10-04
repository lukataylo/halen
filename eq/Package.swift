// swift-tools-version: 6.2
import Foundation
import PackageDescription

// HALEN_APPSTORE=1 builds the Mac App Store variant: no Sparkle (the App
// Store does updates) and an APPSTORE compile flag. Default is the
// Developer ID build that ships from halen.dev.
let appStore = ProcessInfo.processInfo.environment["HALEN_APPSTORE"] == "1"

// Halen — a local-only conversation coach that hears only your side of a
// call. See ../docs/EQ_FEATURES.md for the product brief.
let package = Package(
    name: "HalenEQ",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "halen-eq", targets: ["EQApp"]),
        .executable(name: "eq-analyze", targets: ["EQAnalyze"]),
    ],
    dependencies: [
        // On-device VAD + speaker embeddings (CoreML/ANE) for the voice check.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ] + (appStore ? [] : [
        // Sparkle 2 — signed (EdDSA) auto-updates from halen.dev/eq/appcast.xml.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ]),
    targets: [
        // Pure signal processing, metrics, scoring, storage. No UI, no models
        // that need downloading — everything here is unit-testable offline.
        .target(
            name: "EQCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/EQCore",
            swiftSettings: appStore ? [.define("APPSTORE")] : []
        ),
        .executableTarget(
            name: "EQApp",
            dependencies: ["EQCore"] + (appStore ? [] : [.product(name: "Sparkle", package: "Sparkle")]),
            path: "Sources/EQApp",
            swiftSettings: appStore ? [.define("APPSTORE")] : []
        ),
        // Dev CLI: run the pipeline over an audio file and print the numbers.
        .executableTarget(name: "EQAnalyze", dependencies: ["EQCore"], path: "Sources/EQAnalyze"),
        .testTarget(name: "EQCoreTests", dependencies: ["EQCore"], path: "Tests/EQCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)

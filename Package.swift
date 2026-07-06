// swift-tools-version: 5.10
import PackageDescription

// Halen is a plugin platform: one on-device model, one permission layer, one
// plugin runtime. The target graph *is* the architecture:
//
//   HalenPluginAPI   — the public plugin surface. Protocols, manifest,
//                      events, inference types, and the shared UI/utility kit
//                      plugins are allowed to build on. No host machinery.
//   HalenKit         — the host: model lifecycle, inference scheduling,
//                      permission broker, hotkey registry, plugin runtime
//                      (in-process + external stdio), notch surface manager.
//                      Depends on HalenPluginAPI and implements its services.
//   Plugins/*        — first-party plugins. Each depends on HalenPluginAPI
//                      ONLY. That dependency list is the honesty proof: a
//                      plugin physically cannot import host internals.
//   Halen            — the app shell (menubar UI, settings, permissions
//                      screen, onboarding, Sparkle updater). Wires HalenKit
//                      to the plugin modules.
let package = Package(
    name: "Halen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "halen", targets: ["Halen"]),
    ],
    dependencies: [
        // Sparkle 2.x — the de-facto macOS auto-updater for non-MAS apps.
        // Reads SUFeedURL from Info.plist, EdDSA-verifies update payloads
        // against SUPublicEDKey, replaces the .app in /Applications, and
        // relaunches. See docs/RELEASING.md "Cutting an update" for the
        // release-side appcast.xml regeneration step.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // SwiftTerm — embedded terminal emulator used by Notch Boss to run
        // `claude` sessions inside the notch surface. Pure Swift, no
        // transitive native deps.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // ── Platform ────────────────────────────────────────────────────
        .target(
            name: "HalenPluginAPI",
            path: "Sources/HalenPluginAPI"
        ),
        .target(
            name: "HalenKit",
            dependencies: [
                "HalenPluginAPI",
                "llama",
            ],
            path: "Sources/HalenKit"
        ),

        // ── First-party plugins — HalenPluginAPI only, no exceptions ────
        .target(
            name: "WritingAssistantPlugin",
            dependencies: ["HalenPluginAPI"],
            path: "Sources/Plugins/WritingAssistant"
        ),
        .target(
            name: "SnippetExpanderPlugin",
            dependencies: ["HalenPluginAPI"],
            path: "Sources/Plugins/SnippetExpander"
        ),
        .target(
            name: "VoiceDictationPlugin",
            dependencies: ["HalenPluginAPI"],
            path: "Sources/Plugins/VoiceDictation"
        ),
        .target(
            name: "PromptPolishPlugin",
            dependencies: ["HalenPluginAPI"],
            path: "Sources/Plugins/PromptPolish"
        ),
        .target(
            name: "MotherPlugin",
            dependencies: ["HalenPluginAPI"],
            path: "Sources/Plugins/Mother"
        ),
        .target(
            name: "NotchBossPlugin",
            dependencies: [
                "HalenPluginAPI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Plugins/NotchBoss",
            resources: [.process("Resources")]
        ),

        // ── App shell ───────────────────────────────────────────────────
        .executableTarget(
            name: "Halen",
            dependencies: [
                "HalenKit",
                "HalenPluginAPI",
                "WritingAssistantPlugin",
                "SnippetExpanderPlugin",
                "VoiceDictationPlugin",
                "PromptPolishPlugin",
                "MotherPlugin",
                "NotchBossPlugin",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Halen"
        ),

        // Prebuilt llama.cpp (pinned tag in Vendor/LLAMA_CPP_VERSION). Produced
        // by a macOS-only trim of llama.cpp's build-xcframework.sh.
        .binaryTarget(
            name: "llama",
            path: "Vendor/llama.xcframework"
        ),

        .testTarget(
            name: "HalenTests",
            dependencies: [
                "HalenKit",
                "HalenPluginAPI",
                "WritingAssistantPlugin",
                "SnippetExpanderPlugin",
                "VoiceDictationPlugin",
                "PromptPolishPlugin",
                "MotherPlugin",
                "NotchBossPlugin",
            ],
            path: "Tests/HalenTests"
        ),
    ]
)

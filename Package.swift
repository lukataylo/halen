// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Halen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "halen", targets: ["Halen"]),
    ],
    targets: [
        .executableTarget(
            name: "Halen",
            dependencies: ["llama"],
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
            dependencies: ["Halen"],
            path: "Tests/HalenTests"
        ),
    ]
)

// MLX backend — The Apple-Silicon-native MLX path lives on the
// `mlx-activation` branch, not here. mlx-swift's command-line SwiftPM build
// can't compile its Metal shaders, so any binary built via `swift build`
// against the dep crashes at first use with "Failed to load the default
// metallib." Activating that branch needs an xcodebuild pipeline step (or a
// manual `xcrun metal` over mlx-swift's .metal sources) that produces the
// `mlx-swift_Cmlx.bundle` resource expected by mlx-swift at runtime. Until
// that lands, `main` ships the llama.cpp Qwen 0.5B classifier as the fast
// path — already sub-100 ms warm, which was the original speed goal.

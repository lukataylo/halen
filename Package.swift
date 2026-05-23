// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Halen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "halen", targets: ["Halen"]),
    ],
    // `mlx-swift-examples` brings MLXLLM + MLXLMCommon for the MLX backend
    // (`Sources/Halen/Inference/MLX/`). See the branch README — running this
    // requires an `xcodebuild` step to compile the Metal shaders, since
    // `swift build` alone produces a binary that crashes at first MLX use
    // with "Failed to load the default metallib." Pin floor 2.21 — first
    // release shipping the current `LLMModelFactory` / `ModelContainer` API
    // the backend targets.
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "Halen",
            dependencies: [
                "llama",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
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
            dependencies: ["Halen"],
            path: "Tests/HalenTests"
        ),
    ]
)

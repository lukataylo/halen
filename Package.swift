// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Halen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "halen", targets: ["Halen"]),
    ],
    // MLX backend (deferred): activating `MLXBackend` requires more than just
    // adding the `mlx-swift-examples` dependency — mlx-swift's own README is
    // explicit that **SwiftPM command-line cannot compile its Metal shaders**.
    // The build succeeds, the binary links, but at runtime MLX fails to load
    // `default.metallib` and crashes the process at first use:
    //
    //     MLX error: Failed to load the default metallib. library not found
    //
    // To activate properly the project would need to migrate (or dual-build)
    // through `xcodebuild` so its Metal compiler stage runs and the
    // `mlx-swift_Cmlx` resource bundle gets emitted next to the binary.
    // That's a real engineering arc — new project file, new CI workflow,
    // new build script — and Qwen 0.5B on llama.cpp already gives us
    // sub-100 ms warm classification, so MLX is a perf-ceiling lift, not
    // urgent. Keeping the dependency commented out (and `MLXBackend`
    // compiling as an inert stub via `canImport(MLXLLM)`) until that arc
    // is in scope.
    //
    // dependencies: [
    //     .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.21.0"),
    // ],
    targets: [
        .executableTarget(
            name: "Halen",
            // Add when activating MLX (also requires xcodebuild — see above):
            //     .product(name: "MLXLLM", package: "mlx-swift-examples"),
            //     .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
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

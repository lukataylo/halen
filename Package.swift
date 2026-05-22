// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Halen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "halen", targets: ["Halen"]),
    ],
    // MLX backend (work in progress): to activate `MLXBackend`, uncomment the
    // dependency below and add the `MLXLLM` product to the `Halen` target's
    // `dependencies`. Until then `MLXBackend` compiles as an inert stub
    // (`canImport(MLXLLM)` is false) and the router skips it.
    //
    // dependencies: [
    //     .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.21.0"),
    // ],
    targets: [
        .executableTarget(
            name: "Halen",
            // Add when activating MLX:
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

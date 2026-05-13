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
            path: "Sources/Halen"
        ),
    ]
)

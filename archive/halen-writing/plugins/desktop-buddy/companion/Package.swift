// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DesktopBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DesktopBuddy", targets: ["DesktopBuddy"]),
    ],
    targets: [
        .executableTarget(
            name: "DesktopBuddy",
            path: "Sources/DesktopBuddy"
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobileAICore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MobileAICore", targets: ["MobileAICore"]),
    ],
    targets: [
        .target(
            name: "MobileAICore",
            dependencies: [],
            path: "Sources/MobileAICore"
        ),
        .testTarget(
            name: "MobileAICoreTests",
            dependencies: ["MobileAICore"],
            path: "Tests/MobileAICoreTests"
        ),
    ]
)

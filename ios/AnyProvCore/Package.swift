// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnyProvCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AnyProvCore", targets: ["AnyProvCore"]),
    ],
    targets: [
        .target(
            name: "AnyProvCore",
            dependencies: [],
            path: "Sources/AnyProvCore"
        ),
        .testTarget(
            name: "AnyProvCoreTests",
            dependencies: ["AnyProvCore"],
            path: "Tests/AnyProvCoreTests"
        ),
    ]
)

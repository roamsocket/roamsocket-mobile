// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnyProvCore",
    platforms: [
        // Citadel (SwiftNIO SSH wrapper) requires macOS 14 + iOS 17.
        // The app target already requires iOS 17 so this is a no-op
        // for the app; bumping it keeps the package + app in sync.
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AnyProvCore", targets: ["AnyProvCore"]),
    ],
    dependencies: [
        // SSH client used by the iOS "Auto-setup over SSH" flow. Citadel
        // wraps SwiftNIO SSH with async/await ergonomics. We pin to the
        // main-branch commit that ships `executeCommand` / `executeCommandStream`
        // because no tagged release exposes the exec API yet.
        // Bump this SHA when upgrading and re-verify the API in
        // SSHProvisioner.swift still matches.
        .package(
            url: "https://github.com/orlandos-nl/Citadel.git",
            revision: "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"
        ),
    ],
    targets: [
        .target(
            name: "AnyProvCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Sources/AnyProvCore"
        ),
        .testTarget(
            name: "AnyProvCoreTests",
            dependencies: ["AnyProvCore"],
            path: "Tests/AnyProvCoreTests"
        ),
    ]
)

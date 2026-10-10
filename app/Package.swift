// swift-tools-version: 6.2
// 6.2 so Xcode 26's Swift (6.3) can build it, as well as Xcode 27's. The
// oldest Xcode Kept builds with is in .xcode-version, which CI checks.
import PackageDescription

let package = Package(
    name: "Kept",
    // macOS 26 and later, Apple silicon only: macOS 26 still runs on Intel
    // Macs, but the bundled Python is arm64 and build.sh refuses anything else.
    // Kept uses nothing new in macOS 27; it was lowered from 27 on 2026-10-09
    // so it can be tested on Macs still on 26 and built on standard runners.
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Kept",
            path: "Sources/Kept",
            // The review tools in Settings → Advanced (ReviewTools.swift).
            // In debug builds here; build.sh adds them to local release
            // builds, and leaves them out of what release.sh ships.
            swiftSettings: [.define("KEPT_REVIEW_TOOLS", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "KeptTests",
            dependencies: ["Kept"],
            path: "Tests/KeptTests",
            swiftSettings: [.define("KEPT_REVIEW_TOOLS", .when(configuration: .debug))]
        ),
    ]
)

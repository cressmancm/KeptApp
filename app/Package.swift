// swift-tools-version: 6.4
// 6.4 is the floor for `.macOS(.v27)`; earlier tools don't have that case.
import PackageDescription

let package = Package(
    name: "Kept",
    // macOS 27 and later — which also makes Kept Apple silicon only, since
    // macOS 26 was the last release for Intel Macs.
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(
            name: "Kept",
            path: "Sources/Kept"
        ),
        .testTarget(
            name: "KeptTests",
            dependencies: ["Kept"],
            path: "Tests/KeptTests"
        ),
    ]
)

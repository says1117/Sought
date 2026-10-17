// swift-tools-version:5.9
import PackageDescription

// Pure-logic modules only (no ARKit/UIKit) so they build and test with `swift test` in ios/Recall.
let package = Package(
    name: "Recall",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "Memory", targets: ["Memory"])],
    targets: [
        .target(name: "Memory", path: "Sources/Memory"),
        .testTarget(name: "MemoryTests", dependencies: ["Memory"], path: "Tests/MemoryTests"),
        .target(name: "DriveLinkCore", path: "Sources/DriveLink",
                sources: ["DriveLinkProtocol.swift"]),
        .testTarget(name: "DriveLinkTests", dependencies: ["DriveLinkCore"], path: "Tests/DriveLinkTests"),
    ]
)

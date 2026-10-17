// swift-tools-version:5.9
import PackageDescription

// Pure-logic modules only (no ARKit/UIKit) so they build and test with `swift test`.
let package = Package(
    name: "Recall",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "Memory", targets: ["Memory"])],
    targets: [
        .target(name: "Memory", path: "Sources/Memory"),
        .testTarget(name: "MemoryTests", dependencies: ["Memory"], path: "Tests/MemoryTests"),
    ]
)

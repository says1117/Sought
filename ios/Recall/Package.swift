// swift-tools-version:5.9
import PackageDescription

// Lets the pure DriveLink logic be unit tested without Xcode: `swift test` in ios/Recall.
let package = Package(
    name: "RecallCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    targets: [
        .target(name: "DriveLinkCore", path: "Sources/DriveLink",
                sources: ["DriveLinkProtocol.swift"]),
        .testTarget(name: "DriveLinkTests", dependencies: ["DriveLinkCore"], path: "Tests/DriveLinkTests"),
    ]
)

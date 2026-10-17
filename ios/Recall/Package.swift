// swift-tools-version:5.9
import PackageDescription

// Lets the pure DriveLink, Pose and Controller logic be unit tested without Xcode: `swift test` in ios/Recall.
let package = Package(
    name: "Recall",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "Memory", targets: ["Memory"])],
    targets: [
        .target(name: "Memory", path: "Sources/Memory"),
        .testTarget(name: "MemoryTests", dependencies: ["Memory"], path: "Tests/MemoryTests"),
        .target(name: "DriveLinkCore", path: "Sources/DriveLink",
                sources: ["DriveLinkProtocol.swift"]),
        .target(name: "PoseCore", path: "Sources/Pose", sources: ["PoseMath.swift"]),
        .target(name: "ObstacleGuardCore", path: "Sources/ObstacleGuard",
                sources: ["GuardConfig.swift", "CorridorSampler.swift", "ObstacleGuardLogic.swift"]),
        .target(name: "ControllerCore", dependencies: ["PoseCore"], path: "Sources/Controller",
                sources: ["ControllerMath.swift", "Controller.swift"]),
        .target(name: "SelfTestCore", dependencies: ["PoseCore"], path: "Sources/SelfTest",
                sources: ["SelfTestTypes.swift", "SelfTestMetrics.swift", "SelfTestSteps.swift", "SelfTestEngine.swift"]),
        .testTarget(name: "DriveLinkTests", dependencies: ["DriveLinkCore"], path: "Tests/DriveLinkTests"),
        .testTarget(name: "PoseTests", dependencies: ["PoseCore"], path: "Tests/PoseTests"),
        .testTarget(name: "ObstacleGuardTests", dependencies: ["ObstacleGuardCore"], path: "Tests/ObstacleGuardTests"),
        .testTarget(name: "ControllerTests", dependencies: ["ControllerCore", "PoseCore"], path: "Tests/ControllerTests"),
        .testTarget(name: "SelfTestTests", dependencies: ["SelfTestCore", "PoseCore"], path: "Tests/SelfTestTests"),
    ]
)

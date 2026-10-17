# Role: ios-drive

Owns `ios/Recall/Sources/{DriveLink,Pose,Controller,ObstacleGuard,Explore,ComeToMe,SelfTest}` and the companion app target. Specs: `docs/01_ROBOTICS_PLAN.md` section 3, `docs/03_CONTRACTS.md` sections 0, 1 and 1.1.
SwiftUI, iOS 17+, real device only. Pure logic (controller math, guard thresholds) goes in testable functions with unit tests. Xcode project edits and device runs need the human.

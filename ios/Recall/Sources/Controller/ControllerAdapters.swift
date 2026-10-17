import Foundation

// App-only glue (needs ARKit and CoreBluetooth types, so it is not part of the swift-package target).
// Not compiled by the agent: no Xcode on the machine that wrote it.

extension PoseTracker: PoseSource {
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (pose, tracking) }
}

// DriveLink.drive(left:right:) and stop() already match the protocol.
extension DriveLink: DriveSink {}

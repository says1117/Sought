import Foundation
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(RobotToolsCore)
@testable import RobotToolsCore
#endif

// Ties Scan here to the coordinator's drive lease (DriveLease / LeasedDriveSink / SerialDriveSink) so global STOP,
// pause and backgrounding revoke it. Lives in its own SwiftPM target so the real lease and Controller are testable.

/// One drive-lease token held by a scan. Current only while nothing revoked or superseded it.
final class LeaseScanGrant: ScanDriveGrant {
    private let lease: DriveLease
    private let token: UInt64
    init(lease: DriveLease, token: UInt64) { self.lease = lease; self.token = token }

    var isCurrent: Bool { lease.currentEpoch == token && !lease.manualHeld }
    func run(_ body: () async -> Void) async { await DriveLease.$token.withValue(token, operation: body) }
    func revoke() { lease.revoke(token) }
}

/// Answers the scan's start preconditions from the coordinator and takes the lease for it.
final class LeaseScanGate: ScanHereGate {
    private let lease: DriveLease
    private let coordinatorBusy: () -> Bool
    private let register: (@escaping () -> Void) -> Void
    private let unregister: () -> Void

    /// `coordinatorBusy`: a coordinator task is running or queued. `register`/`unregister` hook runtime cancellation.
    init(lease: DriveLease, coordinatorBusy: @escaping () -> Bool,
         register: @escaping (@escaping () -> Void) -> Void, unregister: @escaping () -> Void) {
        self.lease = lease; self.coordinatorBusy = coordinatorBusy; self.register = register; self.unregister = unregister
    }

    var otherTaskActive: Bool { coordinatorBusy() }
    var manualToolHeld: Bool { lease.manualHeld }

    func acquireDrive() -> ScanDriveGrant? {
        guard let token = lease.grant() else { return nil }     // nil while a manual tool holds the link
        return LeaseScanGrant(lease: lease, token: token)
    }
    func scanStarted(cancel: @escaping () -> Void) { register(cancel) }
    func scanEnded() { unregister() }
}

/// Scan's drive: Controller.rotateBy only. Uses the app's normal Controller turn speed and guards.
final class ControllerScanDrive: ExploreDrive {
    private let controller: Controller
    init(controller: Controller) { self.controller = controller }

    func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult { .failed }   // a scan never drives forward

    func rotateBy(_ deg: Double) async -> DriveResult {
        switch await controller.rotateBy(deg) {
        case .done: return .reached
        case .running: return .failed
        case .failed(.cancelled): return .cancelled
        case .failed(.timeout): return .failed
        case .failed(.trackingLost): return .trackingLost
        }
    }

    func stop() { controller.stop() }
}

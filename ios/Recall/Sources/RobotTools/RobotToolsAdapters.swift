import Foundation

// App-only glue for the Robot tools screen (needs Controller, which lives in another module under swift test).

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

/// Real time for the dwell. Returns early when the scan task is cancelled.
final class ScanSystemClock: ExploreClock {
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
    func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
}

extension PoseSnapshotBox: ExplorePoseSource {}

/// Answers the scan's start preconditions from the coordinator. The screen holds the drive lease as a manual tool
/// ("robot-tools") for as long as it is open, so no coordinator task can start or drive while a scan runs.
final class RuntimeScanGate: ScanHereGate {
    private let coordinator: RobotCoordinator
    init(coordinator: RobotCoordinator) { self.coordinator = coordinator }
    var otherTaskActive: Bool { coordinator.isBusy || coordinator.hasPending }
    /// Other manual tools are sheets too, and iOS shows one sheet at a time, so none can be open under this screen.
    var manualToolHeld: Bool { false }
}

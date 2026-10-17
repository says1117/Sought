import Foundation
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif

// Thread and ownership boundaries between background motion code and the app's mutable pose/BLE objects.
// Hardware safety is not owned here: the ESP32 watchdog and sonar stop independently. These types only keep
// the phone-side producers from fighting over the one drive link.

/// Per-request command revocation plus an exclusive manual-tool hold.
///
/// The coordinator grants a fresh token for each motion request and runs the request with it as a task-local,
/// so every child task inherits it. `LeasedDriveSink` drops drive commands whose token is no longer current
/// or while a manual tool holds the link. STOP is never filtered. A cancelled runner that ignores
/// cancellation therefore cannot drive even after the coordinator has released its slot to a successor.
final class DriveLease {
    @TaskLocal static var token: UInt64?

    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var manualHolders: Set<String> = []

    var manualHeld: Bool { lock.lock(); defer { lock.unlock() }; return !manualHolders.isEmpty }

    /// A new current token, or nil while a manual tool holds the link. Invalidates every earlier token.
    func grant() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard manualHolders.isEmpty else { return nil }
        epoch &+= 1
        return epoch
    }

    /// Invalidate the current token (and so every outstanding one).
    func revoke() { lock.lock(); epoch &+= 1; lock.unlock() }

    /// Invalidate `token` only if it is still the current one; a successor's token is left alone.
    func revoke(_ token: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        if let token, token == epoch { epoch &+= 1 }
    }

    func holdManual(_ tool: String) { lock.lock(); manualHolders.insert(tool); epoch &+= 1; lock.unlock() }
    func releaseManual(_ tool: String) { lock.lock(); manualHolders.remove(tool); lock.unlock() }

    /// Runs `body` only if `token` is current and no manual tool holds the link. The lock is held across
    /// `body`, so once `revoke()` returns no earlier command can still be in flight.
    @discardableResult
    func performIfPermitted(_ token: UInt64?, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let token, token == epoch, manualHolders.isEmpty else { return false }
        body()
        return true
    }
}

/// The drive sink the Controller sees. Drive commands need a current lease token; STOP always passes.
final class LeasedDriveSink: DriveSink {
    private let base: DriveSink
    private let lease: DriveLease
    init(base: DriveSink, lease: DriveLease) { self.base = base; self.lease = lease }
    func drive(left: Int, right: Int) {
        lease.performIfPermitted(DriveLease.token) { base.drive(left: left, right: right) }
    }
    func stop() { base.stop() }
}

/// Serializes all writes to the underlying sink onto one queue (the main queue for DriveLink, whose BLE
/// writes and heartbeat timer live there). A STOP invalidates drive commands queued before it, so a late
/// background drive can never land after the brake.
final class SerialDriveSink: DriveSink {
    private let target: DriveSink
    private let queue: DispatchQueue
    private let isOnQueue: () -> Bool
    private let lock = NSLock()
    private var stopGeneration: UInt64 = 0

    init(target: DriveSink, queue: DispatchQueue, isOnQueue: @escaping () -> Bool = { false }) {
        self.target = target; self.queue = queue; self.isOnQueue = isOnQueue
    }

    func drive(left: Int, right: Int) {
        lock.lock(); let generation = stopGeneration; lock.unlock()
        queue.async { [self] in
            lock.lock(); let current = stopGeneration == generation; lock.unlock()
            if current { target.drive(left: left, right: right) }
        }
    }

    /// Synchronous when already on the queue, otherwise queued behind earlier writes.
    func stop() {
        lock.lock(); stopGeneration &+= 1; lock.unlock()
        if isOnQueue() { target.stop() } else { queue.async { [target] in target.stop() } }
    }
}

/// Immutable copy of the tracker state, safe to hand to background code.
struct PoseSnapshot: Equatable {
    var pose: Pose2D?
    var tracking: TrackingKind
    static let unavailable = PoseSnapshot(pose: nil, tracking: .notAvailable)
}

/// Pose reader for background code. The main thread publishes into it; readers get a value copy. A snapshot
/// older than `maxAgeS` reads as tracking unavailable so a stalled publisher fails closed.
final class PoseSnapshotBox: PoseSource {
    static let maxAgeS = 1.0
    private let lock = NSLock()
    private var snapshot = PoseSnapshot.unavailable
    private var stamp = -Double.infinity
    private let now: () -> Double

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    func update(pose: Pose2D?, tracking: TrackingKind) {
        let t = now()
        lock.lock()
        snapshot = tracking == .notAvailable ? .unavailable : PoseSnapshot(pose: pose, tracking: tracking)
        stamp = t
        lock.unlock()
    }

    func latest() -> (pose: Pose2D?, tracking: TrackingKind) {
        let t = now()
        lock.lock(); let s = snapshot, at = stamp; lock.unlock()
        if t - at > Self.maxAgeS { return (nil, .notAvailable) }
        return (s.pose, s.tracking)
    }
}

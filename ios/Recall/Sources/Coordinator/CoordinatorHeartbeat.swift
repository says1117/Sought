import Foundation
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(SyncCore)
import SyncCore
#endif

/// Builds the heartbeat body (docs/03_CONTRACTS.md section 2.1) from the coordinator's status plus cached sensor
/// values. `snapshot()` only reads cached state under a lock, so the publisher's background thread never touches
/// ARKit, BLE or the coordinator, and a slow network cannot delay driving.
final class CoordinatorHeartbeatSource {
    struct Sensors {
        var pose: Pose2D?
        var tracking: TrackingKind = .notAvailable
        var mapping: MappingKind = .notAvailable
        var frontCm: Int?
        var rearCm: Int?
        var phoneBattery: Double = 0
        var firmwareLink = false
    }

    private let lock = NSLock()
    private var status = CoordinatorStatus.idle
    private var sensors = Sensors()
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// Wire to `RobotCoordinator.onChange` (cheap and non-blocking by design).
    func update(status: CoordinatorStatus) { lock.lock(); self.status = status; lock.unlock() }
    /// Call periodically from whichever thread owns the sensors.
    func update(sensors: Sensors) { lock.lock(); self.sensors = sensors; lock.unlock() }

    func snapshot() -> WireHeartbeat {
        lock.lock(); let st = status, s = sensors; lock.unlock()
        let pose = s.pose ?? Pose2D(x: 0, z: 0, yawDeg: 0)
        return WireHeartbeat(
            t: SyncTime.string(from: now()),
            state: WireHeartbeatState(rawValue: st.state.heartbeatValue) ?? .error,
            task: st.task ?? "",
            tracking: WireTrackingState(rawValue: s.tracking.rawValue) ?? .notAvailable,
            mappingStatus: WireMappingStatus(rawValue: s.mapping.rawValue) ?? .notAvailable,
            pose: WirePose(x: pose.x, z: pose.z, yawDeg: pose.yawDeg),
            frontCm: Double(s.frontCm ?? 999), rearCm: Double(s.rearCm ?? 999),
            phoneBattery: min(1, max(0, s.phoneBattery)), firmwareLink: s.firmwareLink)
    }
}

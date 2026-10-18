import Foundation
#if canImport(NearbyInteraction)
import NearbyInteraction

/// Portrait mount, back camera pointing along rover forward (-device z). Positive bearing is rover-left.
/// Confirm the sign and mount offset with wheels lifted before enabling floor motion.
let BEARING_SIGN: Double = -1
let BEARING_MOUNT_OFFSET_DEG: Double = 0

final class NIRanging: NSObject, NISessionDelegate, RangingSource {
    var onUpdate: (() -> Void)?
    var onInvalidated: ((Error) -> Void)?
    private var session: NISession?
    private var peerToken: NIDiscoveryToken?
    private let lock = NSLock()
    private var sample = RangeSample()

    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    static var isDirectionSupported: Bool { NISession.deviceCapabilities.supportsDirectionMeasurement }
    static var canGuide: Bool { isSupported && isDirectionSupported }

    func latest() -> RangeSample { lock.lock(); defer { lock.unlock() }; return sample }

    /// NI's horizontal vector is x-right, z-toward-screen; atan2 preserves behind/side information.
    static func horizontalBearing(x: Double, y: Double, z: Double) -> Double? {
        guard x.isFinite, y.isFinite, z.isFinite, hypot(x, z) > 0.001 else { return nil }
        let bearing = BEARING_SIGN * atan2(x, -z) * 180 / .pi + BEARING_MOUNT_OFFSET_DEG
        return bearing.isFinite ? bearing : nil
    }

    func prepare() -> String? {
        onMain {
            self.stop()
            guard Self.canGuide else { return nil }
            let s = NISession()
            s.delegateQueue = .main; s.delegate = self
            self.session = s
            guard let token = s.discoveryToken,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
                self.stop(); return nil
            }
            return data.base64EncodedString()
        }
    }

    func run(peerTokenB64: String, cameraAssistance: Bool = false) -> Bool {
        onMain {
            // Never create a second AR session: the robot already owns its pose/camera session.
            guard !cameraAssistance, Self.canGuide, peerTokenB64.utf8.count <= 32 * 1024,
                  let data = Data(base64Encoded: peerTokenB64),
                  let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data),
                  let s = self.session else { return false }
            self.peerToken = token
            self.clear()
            let cfg = NINearbyPeerConfiguration(peerToken: token)
            cfg.isCameraAssistanceEnabled = false
            s.run(cfg)
            return true
        }
    }

    func stop() {
        onMain {
            let old = self.session
            self.session = nil; self.peerToken = nil
            old?.delegate = nil; old?.invalidate()
            self.clear()
        }
    }

    private func clear() {
        lock.lock(); sample = RangeSample(); lock.unlock()
        onUpdate?()
    }

    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard self.session === session, let token = peerToken else { return }
        guard let object = nearbyObjects.first(where: { $0.discoveryToken == token }),
              let distance = object.distance, distance.isFinite, distance > 0,
              let direction = object.direction,
              let bearing = Self.horizontalBearing(x: Double(direction.x), y: Double(direction.y), z: Double(direction.z)) else {
            clear(); return
        }
        let fresh = RangeSample(distanceM: Double(distance), bearingDeg: bearing, updatedAt: ProcessInfo.processInfo.systemUptime)
        lock.lock(); sample = fresh; lock.unlock()
        onUpdate?()
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard self.session === session else { return }
        clear()
        if reason == .peerEnded { stop() }
    }

    func sessionWasSuspended(_ session: NISession) {
        guard self.session === session else { return }
        stop() // fresh token exchange and explicit pairing are required after any suspension
        onInvalidated?(NSError(domain: "SoughtNearby", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ranging suspended. Pair the phones again."]))
    }

    func sessionSuspensionEnded(_ session: NISession) {
        // No automatic resume of a command or an old NI configuration.
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard self.session === session else { return }
        stop()
        onInvalidated?(error)
    }
}
#endif

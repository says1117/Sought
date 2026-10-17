import Foundation
#if canImport(NearbyInteraction)
import NearbyInteraction
#if os(iOS)
import ARKit
#endif

// Nearby Interaction (UWB) wrapper, used by both the robot (Recall) and the Companion app.
// Docs checked by URL only (the pages are JavaScript-rendered and the fetch tool returned titles, not content;
// API shapes below are from memory of those pages and MUST be confirmed in Xcode):
//  - https://developer.apple.com/documentation/nearbyinteraction
//  - https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session
//  - https://developer.apple.com/documentation/nearbyinteraction/nisession
//  - https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration
//  - https://developer.apple.com/documentation/nearbyinteraction/nidiscoverytoken
//  - https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/iscameraassistanceenabled
//  - https://developer.apple.com/documentation/bundleresources/information_property_list/nsnearbyinteractionusagedescription
// Flow: both phones create an NISession, exchange archived NIDiscoveryTokens over MultipeerConnectivity, and each runs an
// NINearbyPeerConfiguration with the OTHER phone's token. Ranging only starts once both sides have run.
//
// Direction: `NINearbyObject.direction` is a unit vector in the device frame, nil when unavailable (peer outside the
// UWB antenna field of view, or the phone held flat/odd). The left/right angle is taken as asin(x) like Apple's
// sample app, assuming the robot phone is mounted upright (portrait) with the back camera facing forward. Sign and
// mount offset are placeholders that must be calibrated: see `BEARING_SIGN` and docs/come-to-me-test.md step 6.
// Camera assistance (iOS 16+, extra direction data from ARKit) is off by default: the robot already runs an
// ARSession for pose and NI needs to be handed that same session; untested, so opt in only after the basic run works.

/// Flip this ONE value if driving toward the peer turns the wrong way. Positive bearing = peer is to the LEFT.
let BEARING_SIGN: Double = -1
/// Degrees added to the computed bearing when the phone is not mounted facing straight ahead.
let BEARING_MOUNT_OFFSET_DEG: Double = 0

final class NIRanging: NSObject, NISessionDelegate, RangingSource {
    var onUpdate: (() -> Void)?
    var onInvalidated: ((Error) -> Void)?

    private var session: NISession?
    private var peerConfig: NINearbyPeerConfiguration?
    private let lock = NSLock()
    private var sample = RangeSample()

    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }

    func latest() -> RangeSample { lock.lock(); defer { lock.unlock() }; return sample }

    /// Creates a fresh session and returns the archived local token as base64, or nil if unsupported.
    func prepare() -> String? {
        guard Self.isSupported else { return nil }
        let s = NISession(); s.delegate = self; session = s
        guard let token = s.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return nil }
        return data.base64EncodedString()
    }

    func run(peerTokenB64: String, cameraAssistance: Bool = false) -> Bool {
        guard let data = Data(base64Encoded: peerTokenB64),
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data),
              let s = session else { return false }
        let cfg = NINearbyPeerConfiguration(peerToken: token)
        #if os(iOS)
        cfg.isCameraAssistanceEnabled = cameraAssistance
        #endif
        peerConfig = cfg
        s.run(cfg)
        return true
    }

    func stop() {
        session?.invalidate(); session = nil; peerConfig = nil
        lock.lock(); sample = RangeSample(); lock.unlock()
    }

    // MARK: NISessionDelegate
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let o = nearbyObjects.first else { return }
        var s = RangeSample()
        if let d = o.distance {
            s.distanceM = Double(d)
            s.updatedAt = ProcessInfo.processInfo.systemUptime
            if let dir = o.direction {
                s.bearingDeg = BEARING_SIGN * asin(Double(max(-1, min(1, dir.x)))) * 180 / .pi + BEARING_MOUNT_OFFSET_DEG
            }
        }
        lock.lock(); sample = s; lock.unlock()
        onUpdate?()
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        // Leave the last timestamp alone: the 2 s staleness rule then ends the approach.
        if reason == .peerEnded { stop() }
    }

    func sessionWasSuspended(_ session: NISession) {}

    func sessionSuspensionEnded(_ session: NISession) {
        if let c = peerConfig { session.run(c) }   // Apple: re-run the configuration after suspension
    }

    func session(_ session: NISession, didInvalidateWith error: Error) { onInvalidated?(error) }
}
#endif

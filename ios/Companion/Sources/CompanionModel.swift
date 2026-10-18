import Foundation
import SwiftUI

protocol HandheldPeerTransport: AnyObject {
    var onMessage: ((CompanionMessage) -> Void)? { get set }
    var onConnection: ((Bool, String?) -> Void)? { get set }
    func start()
    func stop()
    @discardableResult func send(_ message: CompanionMessage) -> Bool
}
extension CompanionLink: HandheldPeerTransport {}

protocol HandheldRanging: AnyObject {
    var onUpdate: (() -> Void)? { get set }
    var onInvalidated: ((Error) -> Void)? { get set }
    func latest() -> RangeSample
    func prepare() -> String?
    func run(peerTokenB64: String, cameraAssistance: Bool) -> Bool
    func stop()
}
extension NIRanging: HandheldRanging {}

/// Foreground paired-phone command lifecycle, independent of saved-place/server commands.
@MainActor
final class CompanionModel: ObservableObject {
    enum Phase: Equatable {
        case idle, searching, connected, requested, approaching, arrived, stopping
        case failed(String), lostContact(String)
    }
    @Published var pairingCode = "" {
        didSet { if started, pairingCode != sessionCode { shutdown() } }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peerName: String?
    @Published private(set) var distanceM: Double?
    @Published private(set) var rangingReady = false
    let uwbSupported: Bool

    private var providedLink: HandheldPeerTransport?
    private let ni: HandheldRanging
    private let clock: () -> Double
    private var commandId: String?
    private var pendingStopId: String?
    private var poll: Timer?
    private var generation = 0
    private var started = false
    private var connected = false
    private var verified = false
    private var rangingConfigured = false
    private var waitingToken: String?
    private var sessionCode: String?

    init(link: HandheldPeerTransport? = nil, ranging: HandheldRanging? = nil,
         supportsGuidance: Bool? = nil, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        providedLink = link; ni = ranging ?? NIRanging()
        uwbSupported = supportsGuidance ?? NIRanging.canGuide
        self.clock = clock
    }

    private var link: HandheldPeerTransport {
        if let providedLink { return providedLink }
        let created = CompanionLink(role: .companion, displayName: "Sought handheld", pairingCode: { [weak self] in self?.pairingCode })
        providedLink = created
        return created
    }

    var canPair: Bool {
        uwbSupported && CompanionLink.validPairingCode(pairingCode) != nil && commandId == nil && phase != .stopping
    }

    /// User action only; foregrounding never silently starts or resumes an approach.
    func start() {
        guard canPair else { return }
        generation += 1
        let g = generation
        sessionCode = pairingCode
        poll?.invalidate(); poll = nil
        connected = false; verified = false; rangingConfigured = false; started = true; waitingToken = nil
        distanceM = nil; rangingReady = false; peerName = nil; phase = .searching
        ni.stop(); link.stop()
        link.onConnection = { [weak self] up, name in
            guard let self, self.generation == g, self.started else { return }
            self.connected = up; self.peerName = name
            if up {
                self.phase = .connected
                guard let token = self.ni.prepare(), self.link.send(.niToken(tokenB64: token)) else {
                    self.shutdown()
                    self.phase = .failed("Could not start nearby ranging. Pair the phones again.")
                    return
                }
            } else {
                if let id = self.commandId { self.pendingStopId = id; self.commandId = nil }
                self.verified = false; self.rangingConfigured = false; self.waitingToken = nil
                self.ni.stop(); self.distanceM = nil; self.rangingReady = false
                self.phase = .lostContact(self.pendingStopId == nil ? "Connection lost. Pair the phones again." : "Connection lost. Stop is not confirmed. Pair again to retry Stop.")
            }
        }
        link.onMessage = { [weak self] message in
            guard let self, self.generation == g, self.started, self.connected else { return }
            self.handle(message)
        }
        ni.onUpdate = { [weak self] in
            guard let self, self.generation == g, self.started else { return }
            self.refreshRange()
        }
        ni.onInvalidated = { [weak self] _ in
            guard let self, self.generation == g, self.started else { return }
            self.shutdown()
            self.phase = .lostContact("Nearby ranging ended. Pair both phones again before requesting movement.")
        }
        link.start()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == g, self.started else { return }
                self.refreshRange()
            }
        }
    }

    static func fresh(_ sample: RangeSample, now: Double) -> Bool {
        guard now.isFinite, let updated = sample.updatedAt, updated.isFinite,
              now >= updated, now - updated <= 2,
              let distance = sample.distanceM, distance.isFinite, distance > 0,
              let bearing = sample.bearingDeg, bearing.isFinite, abs(bearing) <= 180 else { return false }
        return true
    }

    private func refreshRange() {
        let sample = ni.latest()
        rangingReady = started && connected && verified && rangingConfigured && Self.fresh(sample, now: clock())
        distanceM = rangingReady ? sample.distanceM : nil
    }

    private func handle(_ message: CompanionMessage) {
        switch message {
        case let .hello(role, version):
            guard role == .robot, version == CompanionMessage.protocolVersion else {
                shutdown(); phase = .failed("This peer is not a compatible Soughtbot robot."); return
            }
            let wasVerified = verified
            verified = true
            if let token = waitingToken { waitingToken = nil; runPeerToken(token) }
            if !wasVerified, started, connected, let id = pendingStopId { sendStop(id) }
            refreshRange()
        case let .niToken(token):
            if verified { runPeerToken(token) } else { waitingToken = token }
        case let .status(id, state, _, reason):
            guard verified, id == commandId || id == pendingStopId else { return }
            if state == .arrived || state == .failed {
                commandId = nil; pendingStopId = nil
                phase = state == .arrived ? .arrived : .failed(reason ?? "Robot reported that the command ended.")
            } else if pendingStopId == nil {
                if state == .approaching { phase = .approaching }
                else if phase != .approaching { phase = .requested }
            }
        case .comeToMe, .cancel: break
        }
    }

    private func runPeerToken(_ token: String) {
        guard ni.run(peerTokenB64: token, cameraAssistance: false) else {
            shutdown(); phase = .failed("Nearby ranging setup failed. Pair the phones again."); return
        }
        rangingConfigured = true
        refreshRange()
    }

    var canRequest: Bool {
        guard uwbSupported, started, connected, verified, rangingConfigured, commandId == nil, pendingStopId == nil,
              Self.fresh(ni.latest(), now: clock()) else { return false }
        switch phase { case .connected, .arrived, .failed: return true; default: return false }
    }

    func comeToMe() {
        refreshRange()
        guard canRequest else { return }
        let id = CompanionCodec.newCommandId()
        commandId = id; phase = .requested
        if !link.send(.comeToMe(id: id)) {
            pendingStopId = id; commandId = nil
            phase = .lostContact("Request delivery is unknown. Retry Stop before sending another request.")
        }
    }

    var canCancel: Bool { commandId != nil || pendingStopId != nil }

    func cancel() {
        guard let id = pendingStopId ?? commandId else { return }
        pendingStopId = id; commandId = nil
        sendStop(id)
    }

    private func sendStop(_ id: String) {
        phase = .stopping
        if !link.send(.cancel(id: id)) {
            phase = .lostContact("Stop is not confirmed. Keep the robot in view and retry Stop.")
        }
    }

    /// Send cancellation before disconnecting. Peer loss also makes the robot stop, but it is not an ACK.
    func shutdown() {
        if let id = pendingStopId ?? commandId {
            pendingStopId = id
            _ = link.send(.cancel(id: id))
        }
        commandId = nil; generation += 1; started = false; connected = false; verified = false; rangingConfigured = false
        poll?.invalidate(); poll = nil
        link.onConnection = nil; link.onMessage = nil
        ni.onUpdate = nil; ni.onInvalidated = nil
        link.stop(); ni.stop()
        distanceM = nil; rangingReady = false; peerName = nil; waitingToken = nil; sessionCode = nil
        phase = pendingStopId == nil ? .idle : .lostContact("Pair again to confirm Stop before another request.")
    }
}

import Foundation
import Combine

/// Explicit, foreground-only pairing. Radio messages enter the existing coordinator, never a second motion loop.
@MainActor
final class PairedPhoneLink: ObservableObject {
    @Published var code = ""
    @Published private(set) var message = "Enter the same six-digit code on both phones."
    @Published private(set) var connected = false
    @Published private(set) var pairing = false
    @Published private(set) var distance: Double?
    @Published private(set) var bearing: Double?
    @Published var approachEnabled = false {
        didSet {
            guidance.setEnabled(approachEnabled && connected && pairing && NIRanging.canGuide)
            if !approachEnabled { adapter?.cancel() }
        }
    }
    let ranging: NIRanging
    let guidance: PairedGuidanceSource
    var supported: Bool { NIRanging.canGuide }
    private var link: CompanionLink?
    private var coordinator: RobotCoordinator?
    private var adapter: PairedComeToMeAdapter?
    private var optedIn = false
    private var timer: Timer?
    private var current: PairedComeRequest?
    private var task: Task<Void, Never>?
    private var seen: Set<String> = []
    private var verified = false
    private var waitingToken: String?

    init() {
        let ranging = NIRanging()
        self.ranging = ranging
        guidance = PairedGuidanceSource(source: ranging)
    }

    func bind(coordinator: RobotCoordinator, adapter: PairedComeToMeAdapter) {
        self.coordinator = coordinator; self.adapter = adapter
    }

    func beginPairing() {
        guard supported else { message = "This phone cannot provide UWB distance and direction."; return }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            message = "Enter exactly six digits."; return
        }
        endTransport()
        optedIn = true
        seen.removeAll()
        let chosenCode = code
        let link = CompanionLink(role: .robot, displayName: "Sought robot", pairingCode: { chosenCode })
        self.link = link
        link.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        link.onConnection = { [weak self] up, _ in
            MainActor.assumeIsolated { self?.connection(up) }
        }
        ranging.onInvalidated = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.optedIn = false
                self?.endTransport()
                self?.message = "Ranging ended. Pair again before approaching."
            }
        }
        pairing = true
        message = "Waiting for the phone with the matching code."
        link.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let sample = self.ranging.latest()
                let fresh = sample.updatedAt.map { ProcessInfo.processInfo.systemUptime - $0 <= 1 } ?? false
                self.distance = fresh ? sample.distanceM : nil
                self.bearing = fresh ? sample.bearingDeg : nil
            }
        }
    }

    func stopPairing() { optedIn = false; endTransport(); message = "Pairing stopped." }
    func resume() {} // Pairing and approach permission always require a fresh user action.
    func suspend() { optedIn = false; endTransport(); message = "Pair again after returning to the app." }

    private func endTransport() {
        approachEnabled = false
        cancelCurrent()
        timer?.invalidate(); timer = nil
        let old = link; link = nil
        old?.onMessage = nil; old?.onConnection = nil
        old?.stop()
        ranging.stop()
        connected = false; pairing = false; distance = nil; bearing = nil
        verified = false; waitingToken = nil
    }

    private func connection(_ up: Bool) {
        approachEnabled = false
        connected = up
        verified = false; waitingToken = nil
        if up {
            if let token = ranging.prepare() { link?.send(.niToken(tokenB64: token)) }
            message = "Paired. Check straight ahead, left and right while the robot is stationary."
        } else {
            optedIn = false
            endTransport()
            message = "Phone disconnected. Pair both phones again."
        }
    }

    private func handle(_ message: CompanionMessage) {
        switch message {
        case .niToken(let token):
            guard connected else { return }
            if verified { runPeerToken(token) } else { waitingToken = token }
        case .hello(let role, let version):
            guard role == .companion, version == CompanionMessage.protocolVersion else { stopPairing(); return }
            verified = true
            if let token = waitingToken { waitingToken = nil; runPeerToken(token) }
        case .comeToMe(let id): beginRequest(id)
        case .cancel(let id):
            if current?.id == id { cancelCurrent() }
            else { link?.send(.status(id: id, state: .failed, distanceM: nil, reason: "cancelled")) }
        case .status: break
        }
    }

    private func beginRequest(_ id: String) {
        guard connected, verified, !id.isEmpty, id.utf8.count <= 128, let coordinator else { return }
        guard !seen.contains(id) else { return }
        guard seen.count < 1024 else { link?.send(.status(id: id, state: .failed, distanceM: nil, reason: "Pair again to start a new session.")); return }
        seen.insert(id)
        guard current == nil else { link?.send(.status(id: id, state: .failed, distanceM: nil, reason: "busy")); return }
        let epoch = coordinator.stopGeneration
        let request = PairedComeRequest(id: id)
        current = request
        task = Task { [weak self] in
            let outcome: CoordinatorCallOutcome
            do {
                outcome = try await PairedComeContext.$request.withValue(request) {
                    try await coordinator.executeRemote(.comeToMe, generation: epoch)
                }
            } catch {
                guard let self, self.current === request else { return }
                self.progress(request, state: .failed, distance: nil, reason: "approach_cancelled_or_failed")
                self.current = nil; self.task = nil
                return
            }
            guard let self, self.current === request else { return }
            switch outcome {
            case .done: self.progress(request, state: .arrived, distance: self.ranging.latest().distanceM, reason: nil)
            case .busy(let reason), .failed(let reason): self.progress(request, state: .failed, distance: nil, reason: reason)
            }
            self.current = nil; self.task = nil
        }
    }

    private func runPeerToken(_ token: String) {
        if !ranging.run(peerTokenB64: token) {
            approachEnabled = false
            message = "Could not start ranging. Pair again."
        }
    }

    func progress(_ request: PairedComeRequest?, state: CompanionState, distance: Double?, reason: String?) {
        guard let request, current === request, !request.isCancelled, connected else { return }
        link?.send(.status(id: request.id, state: state, distanceM: distance, reason: reason))
    }

    private func cancelCurrent() {
        guard let request = current else { return }
        adapter?.cancel(request: request)
        task?.cancel()
        link?.send(.status(id: request.id, state: .failed, distanceM: nil, reason: "cancelled"))
        current = nil; task = nil
    }
}

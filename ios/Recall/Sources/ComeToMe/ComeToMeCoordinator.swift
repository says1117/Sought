import Foundation
#if canImport(MultipeerConnectivity) && canImport(NearbyInteraction)

// Robot-side glue: companion link + NI + runner. App target only, not compiled by the agent.
// Wiring to do in the app (not done here, see PR body): create one of these where DriveLink and PoseTracker exist,
// call `start()`, and publish `isActive` as heartbeat state `coming_to_user` (contract 2.1).

final class ComeToMeCoordinator {
    private let link = CompanionLink(role: .robot, displayName: "Recall robot")
    private let ni = NIRanging()
    private let makeMotion: () -> ApproachMotion
    private let detector: PersonDetector?
    private var runner: ComeToMeRunner?
    private var task: Task<Void, Never>?
    private(set) var isActive = false
    private var activeId: String?

    init(makeMotion: @escaping () -> ApproachMotion, detector: PersonDetector?) {
        self.makeMotion = makeMotion; self.detector = detector
        link.onMessage = { [weak self] in self?.handle($0) }
        link.onConnection = { [weak self] up, _ in
            guard let self else { return }
            if up { if let t = self.ni.prepare() { self.link.send(.niToken(tokenB64: t)) } }
            else { self.runner?.cancel() }   // link lost mid-approach: stop (safe default)
        }
    }

    func start() { link.start() }
    func stop() { runner?.cancel(); link.stop(); ni.stop() }

    private func handle(_ m: CompanionMessage) {
        switch m {
        case let .niToken(b64): _ = ni.run(peerTokenB64: b64)
        case let .comeToMe(id): begin(id)
        case let .cancel(id): if id == activeId { runner?.cancel() }
        case .hello, .status: break
        }
    }

    private func begin(_ id: String) {
        guard !isActive else { link.send(.status(id: id, state: .failed, distanceM: nil, reason: "busy")); return }
        guard NIRanging.isSupported else { link.send(.status(id: id, state: .failed, distanceM: nil, reason: "uwb_unsupported")); return }
        isActive = true; activeId = id
        let r = ComeToMeRunner(ranging: ni, motion: makeMotion(), detector: detector) { [weak self] state, dist, reason in
            self?.link.send(.status(id: id, state: state, distanceM: dist, reason: reason))
        }
        runner = r
        task = Task { [weak self] in
            await r.run()
            self?.isActive = false; self?.activeId = nil
        }
    }
}
#endif

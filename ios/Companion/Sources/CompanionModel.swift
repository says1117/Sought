import Foundation
import SwiftUI

// Companion app model (plan v2 section 3.6). Shares CompanionMessages.swift, CompanionLink.swift and NIRanging.swift
// with the robot app (add them to this target by path, see README). Not compiled or run: no Xcode here, and it needs
// two physical iPhones with U1/U2 chips (docs/come-to-me-test.md).

@MainActor
final class CompanionModel: ObservableObject {
    enum Phase: Equatable { case searching, connected, requested, approaching, arrived, failed(String) }

    @Published var phase: Phase = .searching
    @Published var peerName: String?
    @Published var distanceM: Double?       // our own UWB reading, falls back to the robot's status distance
    @Published var uwbSupported = NIRanging.isSupported

    private let link = CompanionLink(role: .companion, displayName: "Recall companion")
    private let ni = NIRanging()
    private var commandId: String?
    private var poll: Timer?

    func start() {
        link.onConnection = { [weak self] up, name in
            guard let self else { return }
            self.peerName = name
            if up {
                self.phase = .connected
                if let t = self.ni.prepare() { self.link.send(.niToken(tokenB64: t)) }
            } else {
                self.phase = .searching; self.distanceM = nil; self.ni.stop()
            }
        }
        link.onMessage = { [weak self] in self?.handle($0) }
        link.start()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let d = self.ni.latest().distanceM else { return }
                self.distanceM = d
            }
        }
    }

    private func handle(_ m: CompanionMessage) {
        switch m {
        case let .niToken(b64): _ = ni.run(peerTokenB64: b64)
        case let .status(id, state, dist, reason):
            guard id == commandId else { return }
            if let dist { distanceM = distanceM ?? dist }
            switch state {
            case .accepted: phase = .requested
            case .approaching: phase = .approaching
            case .arrived: phase = .arrived
            case .failed: phase = .failed(reason ?? "failed")
            }
        case .hello, .comeToMe, .cancel: break
        }
    }

    func comeToMe() {
        let id = CompanionCodec.newCommandId()
        commandId = id; phase = .requested
        link.send(.comeToMe(id: id))
    }

    func cancel() {
        if let id = commandId { link.send(.cancel(id: id)) }
        phase = peerName == nil ? .searching : .connected
    }

    var canRequest: Bool {
        switch phase { case .connected, .arrived, .failed: return true; default: return false }
    }
    var canCancel: Bool {
        switch phase { case .requested, .approaching: return true; default: return false }
    }
}

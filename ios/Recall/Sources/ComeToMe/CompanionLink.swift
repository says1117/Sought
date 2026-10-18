import Foundation
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// Foreground, explicitly paired, single-peer transport. The shared six-digit code travels only in the
/// invitation context, never in discovery advertisements. Start again to change the paired session.
final class CompanionLink: NSObject {
    var onMessage: ((CompanionMessage) -> Void)?
    var onConnection: ((Bool, String?) -> Void)?
    private let role: CompanionRole
    private let me: MCPeerID
    private let pairingCode: () -> String?
    private var activeCode: String?
    private var session: MCSession?
    private var peer: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discovered: [MCPeerID] = []
    private var tried: Set<MCPeerID> = []
    private var hadConnection = false

    init(role: CompanionRole, displayName: String, pairingCode: @escaping () -> String? = { nil }) {
        self.role = role; self.pairingCode = pairingCode
        me = MCPeerID(displayName: displayName)
        super.init()
    }

    static func validPairingCode(_ code: String?) -> String? {
        guard let code, code.utf8.count == 6, code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return code
    }

    func start() {
        onMain {
            self.stop()
            guard let code = Self.validPairingCode(self.pairingCode()) else { return }
            self.activeCode = code
            let session = MCSession(peer: self.me, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self; self.session = session
            switch self.role {
            case .companion:
                let a = MCNearbyServiceAdvertiser(peer: self.me, discoveryInfo: nil, serviceType: CompanionMessage.serviceType)
                a.delegate = self; self.advertiser = a; a.startAdvertisingPeer()
            case .robot:
                let b = MCNearbyServiceBrowser(peer: self.me, serviceType: CompanionMessage.serviceType)
                b.delegate = self; self.browser = b; b.startBrowsingForPeers()
            }
        }
    }

    func stop() {
        onMain {
            self.advertiser?.stopAdvertisingPeer(); self.browser?.stopBrowsingForPeers()
            self.advertiser?.delegate = nil; self.browser?.delegate = nil
            let old = self.session
            self.session = nil; self.peer = nil; self.activeCode = nil
            self.advertiser = nil; self.browser = nil; self.discovered = []; self.tried = []; self.hadConnection = false
            old?.delegate = nil; old?.disconnect()
        }
    }

    @discardableResult func send(_ message: CompanionMessage) -> Bool {
        onMain {
            guard let session = self.session, let peer = self.peer,
                  session.connectedPeers == [peer], let data = try? CompanionCodec.encode(message) else { return false }
            do { try session.send(data, toPeers: [peer], with: .reliable); return true }
            catch { return false }
        }
    }

    private func inviteNext() {
        guard role == .robot, peer == nil, let browser, let session, let code = activeCode,
              let next = discovered.first(where: { !tried.contains($0) }) else { return }
        peer = next; tried.insert(next)
        browser.invitePeer(next, to: session, withContext: Data(code.utf8), timeout: 10)
    }

    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
    private func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }
}

extension CompanionLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        main {
            guard self.session === session, self.peer == peerID else { return }
            switch state {
            case .connected:
                guard session.connectedPeers == [peerID] else { self.stop(); self.onConnection?(false, nil); return }
                self.hadConnection = true
                self.advertiser?.stopAdvertisingPeer(); self.browser?.stopBrowsingForPeers()
                self.onConnection?(true, peerID.displayName)
                self.send(.hello(role: self.role, version: CompanionMessage.protocolVersion))
            case .notConnected:
                if self.hadConnection {
                    self.stop() // a fresh pairing/session is required; no queued callbacks can rejoin it
                    self.onConnection?(false, nil)
                } else {
                    self.peer = nil
                    self.inviteNext()
                }
            case .connecting: break
            @unknown default: break
            }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 64 * 1024, let message = try? CompanionCodec.decode(data) else { return }
        main {
            guard self.session === session, self.peer == peerID, session.connectedPeers == [peerID] else { return }
            self.onMessage?(message)
        }
    }
    func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

extension CompanionLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        main {
            guard self.advertiser === advertiser, self.role == .companion, self.peer == nil,
                  let session = self.session, session.connectedPeers.isEmpty,
                  let code = self.activeCode, context == Data(code.utf8) else {
                invitationHandler(false, nil); return
            }
            self.peer = peerID
            invitationHandler(true, session)
        }
    }
}

extension CompanionLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        main {
            guard self.browser === browser else { return }
            if !self.discovered.contains(peerID) { self.discovered.append(peerID) }
            self.inviteNext()
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        main { if self.browser === browser { self.discovered.removeAll { $0 == peerID } } }
    }
}
#endif

import Foundation
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

// Companion link transport (docs/03_CONTRACTS.md section 1.1, docs/01_ROBOTICS_PLAN.md section 3.6).
// The companion advertises, the robot browses and invites. Service type `recall-ni`.
// Docs (see NSBonjourServices note in docs/come-to-me-test.md; fetched by URL only, content not machine-readable here):
//  - https://developer.apple.com/documentation/multipeerconnectivity
//  - https://developer.apple.com/documentation/multipeerconnectivity/mcnearbyserviceadvertiser
//  - https://developer.apple.com/documentation/multipeerconnectivity/mcnearbyservicebrowser
//  - https://developer.apple.com/documentation/multipeerconnectivity/mcsession
//  - https://developer.apple.com/documentation/bundleresources/information_property_list/nslocalnetworkusagedescription
//  - https://developer.apple.com/documentation/bundleresources/information_property_list/nsbonjourservices
//
// SECURITY: the companion auto-accepts any invitation on this service type, so anyone nearby running the Recall robot
// build could connect. Fine for a demo; for anything else add an approval step or an invitation context check.

final class CompanionLink: NSObject {
    var onMessage: ((CompanionMessage) -> Void)?
    var onConnection: ((Bool, String?) -> Void)?      // connected?, peer display name

    private let role: CompanionRole
    private let me: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    init(role: CompanionRole, displayName: String) {
        self.role = role
        me = MCPeerID(displayName: displayName)
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func start() {
        switch role {
        case .companion:
            let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: CompanionMessage.serviceType)
            a.delegate = self; a.startAdvertisingPeer(); advertiser = a
        case .robot:
            let b = MCNearbyServiceBrowser(peer: me, serviceType: CompanionMessage.serviceType)
            b.delegate = self; b.startBrowsingForPeers(); browser = b
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers(); session.disconnect()
        advertiser = nil; browser = nil
    }

    func send(_ m: CompanionMessage) {
        guard !session.connectedPeers.isEmpty, let data = try? CompanionCodec.encode(m) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func main(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
}

extension CompanionLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        main {
            self.onConnection?(state == .connected, state == .connected ? peerID.displayName : nil)
            if state == .connected { self.send(.hello(role: self.role, version: CompanionMessage.protocolVersion)) }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = try? CompanionCodec.decode(data) else { return }   // ignore malformed
        main { self.onMessage?(m) }
    }
    func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

extension CompanionLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension CompanionLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
#endif

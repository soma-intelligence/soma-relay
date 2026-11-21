import Foundation
@preconcurrency import MultipeerConnectivity

/// A phone discovered on the mesh (advertising, maybe not connected yet).
struct NearbyPeer: Identifiable, Equatable {
    let id: String
    /// Short code shown in the path card (`K7`).
    let code: String
    let name: String?
    let compactLink: String?
    var connected: Bool
}

@MainActor protocol MeshTransportDelegate: AnyObject {
    func mesh(_ mesh: MeshTransport, received frame: Data, fromLink link: UInt32, peerCode: String)
    func mesh(_ mesh: MeshTransport, control: MeshControl, from peer: String)
    func meshPeersChanged(_ mesh: MeshTransport)
}

/// Link-level control messages between direct neighbours (not routed).
nonisolated struct MeshControl: Codable, Sendable {
    /// "card-req" | "card"
    var t: String
    var card: String?
}

/// MultipeerConnectivity mesh: Bluetooth + peer-to-peer Wi-Fi, no Internet needed. Every instance
/// advertises and browses `soma-relay`, connects to up to 8 peers and moves opaque core frames.
/// Forwarding adds 10-120 ms of random jitter so relays cannot be timed.
final class MeshTransport: NSObject {
    static let serviceType = "soma-relay"
    static let maxPeers = 8
    /// Frames bigger than this are split by the router.
    static let mtu: UInt32 = 16 * 1024

    weak var delegate: MeshTransportDelegate?

    private let myPeer: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var links: [MCPeerID: UInt32] = [:]
    private var nextLink: UInt32 = 1
    private var discovered: [MCPeerID: [String: String]] = [:]
    private(set) var running = false
    private var advertisedInfo: [String: String] = [:]

    let code: String

    override init() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<4).map { _ in alphabet.randomElement()! })
        self.code = code
        myPeer = MCPeerID(displayName: code)
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    var connectedCount: Int { session.connectedPeers.count }

    var peers: [NearbyPeer] {
        let connected = Set(session.connectedPeers)
        var all: [NearbyPeer] = session.connectedPeers.map { peer in
            let info = discovered[peer] ?? [:]
            return NearbyPeer(id: peer.displayName, code: String(peer.displayName.prefix(2)), name: info["n"], compactLink: info["c"], connected: true)
        }
        for (peer, info) in discovered where !connected.contains(peer) {
            all.append(NearbyPeer(id: peer.displayName, code: String(peer.displayName.prefix(2)), name: info["n"], compactLink: info["c"], connected: false))
        }
        return all.sorted { $0.id < $1.id }
    }

    /// `visibleName` / `compactLink`: shown to nearby phones only when the user is visible.
    func start(visibleName: String?, compactLink: String?) {
        var info: [String: String] = [:]
        if let visibleName { info["n"] = String(visibleName.prefix(40)) }
        if let compactLink, compactLink.count < 200 { info["c"] = compactLink }
        if running, info == advertisedInfo { return }
        stopAdvertising()
        advertisedInfo = info
        let advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: info.isEmpty ? nil : info, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        if browser == nil {
            let browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
        }
        running = true
    }

    private func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    func stop() {
        stopAdvertising()
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        links = [:]
        discovered = [:]
        running = false
        delegate?.meshPeersChanged(self)
    }

    /// Sends core frames to every connected peer except `excluding`.
    func broadcast(_ frames: [Data], excluding: UInt32? = nil, jitter: Bool = false) {
        let targets = session.connectedPeers.filter { links[$0] != excluding }
        guard !targets.isEmpty else { return }
        let payloads = frames.map { frame -> Data in
            var d = Data([0x01])
            d.append(frame)
            return d
        }
        let session = self.session
        if jitter {
            let delay = Double.random(in: 0.010...0.120)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for p in payloads { try? session.send(p, toPeers: targets, with: .reliable) }
            }
        } else {
            for p in payloads { try? session.send(p, toPeers: targets, with: .reliable) }
        }
    }

    func sendControl(_ control: MeshControl, to peerId: String) {
        guard let peer = session.connectedPeers.first(where: { $0.displayName == peerId }),
            let json = try? JSONEncoder().encode(control)
        else { return }
        var d = Data([0x02])
        d.append(json)
        try? session.send(d, toPeers: [peer], with: .reliable)
    }

    func invite(_ peerId: String) {
        guard let peer = discovered.keys.first(where: { $0.displayName == peerId }), let browser else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    private func link(for peer: MCPeerID) -> UInt32 {
        if let l = links[peer] { return l }
        let l = nextLink
        nextLink += 1
        links[peer] = l
        return l
    }

    // Main-actor handlers (the delegates hop here).

    fileprivate func handleState(_ peer: MCPeerID, _ state: MCSessionState) {
        switch state {
        case .connected: _ = link(for: peer)
        case .notConnected: links[peer] = nil
        default: break
        }
        delegate?.meshPeersChanged(self)
    }

    fileprivate func handleData(_ data: Data, from peer: MCPeerID) {
        guard let kind = data.first else { return }
        let body = data.dropFirst()
        switch kind {
        case 0x01:
            delegate?.mesh(self, received: Data(body), fromLink: link(for: peer), peerCode: String(peer.displayName.prefix(2)))
        case 0x02:
            if let control = try? JSONDecoder().decode(MeshControl.self, from: Data(body)) {
                delegate?.mesh(self, control: control, from: peer.displayName)
            }
        default:
            break
        }
    }

    fileprivate func handleFound(_ peer: MCPeerID, info: [String: String]?) {
        discovered[peer] = info ?? [:]
        if session.connectedPeers.count < Self.maxPeers, myPeer.displayName < peer.displayName,
            !session.connectedPeers.contains(peer)
        {
            browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
        }
        delegate?.meshPeersChanged(self)
    }

    fileprivate func handleLost(_ peer: MCPeerID) {
        discovered[peer] = nil
        delegate?.meshPeersChanged(self)
    }

    fileprivate var canAccept: Bool { session.connectedPeers.count < Self.maxPeers }
    fileprivate var currentSession: MCSession { session }
}

extension MeshTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.handleState(peerID, state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handleData(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MeshTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        nonisolated(unsafe) let handler = invitationHandler
        Task { @MainActor in
            handler(self.canAccept, self.canAccept ? self.currentSession : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}
}

extension MeshTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.handleFound(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.handleLost(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
}

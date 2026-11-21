import Foundation

@MainActor protocol NodeClientDelegate: AnyObject {
    func node(_ node: NodeClient, received envelope: Data)
    func nodeStateChanged(_ node: NodeClient)
    func node(_ node: NodeClient, presence online: Set<String>)
}

/// Client of an optional relay node (spec section 7): WebSocket mailbox with challenge auth,
/// store-and-forward, presence, plus the HTTP directory, cards, blobs and ICE list.
/// Reconnects with exponential backoff (1 s to 60 s).
final class NodeClient {
    enum State: Equatable {
        case off, connecting, authenticating, ready
        case failed(String)
    }

    weak var delegate: NodeClientDelegate?
    private(set) var state: State = .off
    private(set) var baseURL: URL

    private let core: () -> RelayCoreAPI?
    private let card: () -> String?
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var backoff: Double = 1
    private var reconnect: Task<Void, Never>?
    private var generation = 0
    private var wanted = false

    init(baseURL: URL, core: @escaping () -> RelayCoreAPI?, card: @escaping () -> String?) {
        self.baseURL = baseURL
        self.core = core
        self.card = card
    }

    var isReady: Bool { state == .ready }

    func setBaseURL(_ url: URL) {
        guard url != baseURL else { return }
        baseURL = url
        if wanted { disconnect(); connect() }
    }

    private var wsURL: URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        c.path = "/v1/ws"
        return c.url!
    }

    func connect() {
        wanted = true
        guard task == nil, let core = core() else { return }
        generation += 1
        let gen = generation
        let task = session.webSocketTask(with: wsURL)
        self.task = task
        set(.connecting)
        task.resume()
        send(["t": "hello", "mailbox": core.mailboxHex(), "pub": core.deviceSigningPublic().base64url])
        receiveLoop(task, gen: gen)
    }

    func disconnect() {
        wanted = false
        reconnect?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        set(.off)
    }

    private func set(_ s: State) {
        state = s
        delegate?.nodeStateChanged(self)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            let text: String?
            let failed: String?
            switch result {
            case .success(.string(let s)): text = s; failed = nil
            case .success(.data(let d)): text = String(data: d, encoding: .utf8); failed = nil
            case .success: text = nil; failed = nil
            case .failure(let e): text = nil; failed = e.localizedDescription
            }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let failed {
                    self.dropped(failed)
                    return
                }
                if let text { self.handle(text) }
                self.receiveLoop(task, gen: gen)
            }
        }
    }

    private func dropped(_ reason: String) {
        task = nil
        set(.failed(reason))
        guard wanted else { return }
        let delay = backoff
        backoff = min(60, backoff * 2)
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let t = obj["t"] as? String else { return }
        switch t {
        case "challenge":
            guard let nonceText = obj["nonce"] as? String, let nonce = Data(base64url: nonceText) ?? Data(base64Encoded: nonceText),
                let core = core()
            else { return }
            set(.authenticating)
            send(["t": "auth", "sig": core.signNodeChallenge(nonce: nonce).base64url])
            if let card = card() {
                send(["t": "register", "card": Data(card.utf8).base64url])
            }
        case "ready", "registered", "sent", "pong":
            if state != .ready {
                backoff = 1
                set(.ready)
            }
        case "env":
            if state != .ready { backoff = 1; set(.ready) }
            guard let envText = obj["env"] as? String, let env = Data(base64url: envText) else { return }
            delegate?.node(self, received: env)
            if let id = obj["id"] as? String { send(["t": "ack", "id": id]) }
        case "presence":
            let online = Set((obj["online"] as? [String]) ?? [])
            delegate?.node(self, presence: online)
        case "error":
            if state != .ready { set(.failed((obj["msg"] as? String) ?? "Erreur du nœud")) }
        default:
            // Any other frame after auth means the node accepted us.
            if state == .authenticating { backoff = 1; set(.ready) }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// Returns false when the node is not ready (caller queues).
    @discardableResult func send(envelope: Data, to mailbox: String) -> Bool {
        guard state == .ready else { return false }
        send(["t": "send", "to": mailbox, "env": envelope.base64url])
        return true
    }

    func queryPresence(_ mailboxes: [String]) {
        guard state == .ready, !mailboxes.isEmpty else { return }
        send(["t": "presence", "mailboxes": mailboxes])
    }

    // MARK: HTTP

    private func http(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    /// `handle` without the `@node` part. Returns a `relay1:` card.
    func lookup(handle: String, on node: URL? = nil) async throws -> String {
        let url = (node ?? baseURL).appendingPathComponent("v1/directory/\(handle.lowercased())")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        return Self.card(from: data)
    }

    func card(mailbox: String, on node: URL? = nil) async throws -> String {
        let url = (node ?? baseURL).appendingPathComponent("v1/cards/\(mailbox)")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        return Self.card(from: data)
    }

    private static func card(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let card = obj["card"] as? String {
            if card.hasPrefix("relay1:") { return card }
            if let d = Data(base64url: card), let s = String(data: d, encoding: .utf8) { return s }
            return card
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// `PUT /v1/directory/{handle}`: body = the card exactly, `X-Relay-Mailbox` = mailbox hex,
    /// `X-Relay-Sig` = base64url (no padding) of the directory signature.
    func publish(handle: String, card: String, mailbox: String, signature: Data) async throws(PublishError) {
        var request = URLRequest(url: http("v1/directory/\(handle.lowercased())"))
        request.httpMethod = "PUT"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mailbox, forHTTPHeaderField: "X-Relay-Mailbox")
        request.setValue(signature.base64url, forHTTPHeaderField: "X-Relay-Sig")
        request.httpBody = Data(card.utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw .network }
        guard let code = (response as? HTTPURLResponse)?.statusCode else { throw .network }
        if (200..<300).contains(code) { return }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw .refused(code: obj?["error"] as? String ?? "http_\(code)")
    }

    nonisolated enum PublishError: LocalizedError {
        case network
        case refused(code: String)

        var errorDescription: String? {
            switch self {
            case .network: "Nœud injoignable."
            case .refused("handle_taken"): "Ce pseudo est déjà pris sur ce nœud."
            case .refused("too_many_handles"): "Ce compte a déjà 5 pseudos sur ce nœud."
            case .refused("unknown_mailbox"): "Le nœud ne te connaît pas encore. Reconnecte-toi puis réessaie."
            case .refused("bad_handle"): "Pseudo : 3 à 32 caractères parmi a-z, 0-9, _ . -"
            case .refused("bad_signature"): "Signature refusée par le nœud."
            case .refused("card_rejected"): "Le nœud a refusé ta carte."
            case .refused(let code): "Publication refusée (\(code))."
            }
        }
    }

    func uploadBlob(_ data: Data, sha: String) async throws -> String {
        let url = http("v1/blobs/\(sha)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: data)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        return url.absoluteString
    }

    func downloadBlob(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        return data
    }

    nonisolated struct IceServer: Decodable, Sendable {
        var urls: [String]
        var username: String?
        var credential: String?

        enum CodingKeys: String, CodingKey { case urls, username, credential }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let many = try? c.decode([String].self, forKey: .urls) { urls = many } else { urls = [try c.decode(String.self, forKey: .urls)] }
            username = try c.decodeIfPresent(String.self, forKey: .username)
            credential = try c.decodeIfPresent(String.self, forKey: .credential)
        }

        init(urls: [String]) { self.urls = urls }
    }

    func iceServers() async -> [IceServer] {
        let fallback = [IceServer(urls: ["stun:stun.l.google.com:19302"])]
        guard let (data, _) = try? await session.data(from: http("v1/ice")) else { return fallback }
        if let list = try? JSONDecoder().decode([IceServer].self, from: data) { return list }
        struct Wrapped: Decodable { var iceServers: [IceServer]?; var ice_servers: [IceServer]? }
        if let w = try? JSONDecoder().decode(Wrapped.self, from: data), let list = w.iceServers ?? w.ice_servers { return list }
        return fallback
    }
}

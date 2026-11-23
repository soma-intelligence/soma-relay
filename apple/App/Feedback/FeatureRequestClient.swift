import Foundation

/// "Suggérer une fonctionnalité": one POST to the Soma Labs feature-request function. This is a
/// plain HTTPS request to the company backend. It never goes through the mesh, the node or the
/// end-to-end encryption, and the sheet says so.
nonisolated struct FeatureRequestClient: Sendable {
    static let defaultEndpoint = URL(string: "https://uchdtnhkkclhvnnqclht.supabase.co/functions/v1/feature-request")!
    static let appID = "soma_relay"
    static let platform = "ios"
    static let minLength = 3
    static let maxLength = 4000
    static let installIDKey = "FeatureRequestInstallID"

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The JSON body of the backend, keys as it expects them. Nil optionals are left out.
    struct Payload: Encodable, Equatable, Sendable {
        var app = FeatureRequestClient.appID
        var platform = FeatureRequestClient.platform
        var message: String
        var email: String?
        var installID: String?
        var appVersion: String?
        var osVersion: String?
        var deviceModel: String?
        var locale: String?

        enum CodingKeys: String, CodingKey {
            case app, platform, message, email, locale
            case installID = "install_id"
            case appVersion = "app_version"
            case osVersion = "os_version"
            case deviceModel = "device_model"
        }
    }

    enum Failure: Error, Equatable {
        case messageTooShort, messageTooLong, invalidEmail, rateLimited, server, network
        case rejected(String)

        /// French copy for the sheet, the person's text stays in place.
        var message: String {
            switch self {
            case .messageTooShort: "Ton idée est trop courte. Écris au moins \(FeatureRequestClient.minLength) caractères."
            case .messageTooLong: "Ton idée dépasse \(FeatureRequestClient.maxLength) caractères."
            case .invalidEmail: "Cette adresse e-mail n'a pas l'air valide."
            case .rateLimited: "Trop d'idées en peu de temps. Réessaie dans une heure."
            case .server, .rejected: "Envoi impossible pour le moment. Réessaie plus tard."
            case .network: "Envoi impossible. Vérifie ta connexion et réessaie."
            }
        }
    }

    var endpoint: URL = Self.defaultEndpoint
    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    // MARK: Validation

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// At least 3 non-space characters and at most 4000 once trimmed.
    static func canSend(_ message: String) -> Bool {
        visibleCount(message) >= minLength && trimmed(message).count <= maxLength
    }

    /// Characters other than spaces and line breaks.
    static func visibleCount(_ text: String) -> Int {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// Light client check; the backend has the last word.
    static func isPlausibleEmail(_ email: String) -> Bool {
        let value = trimmed(email)
        guard value.count <= 320, !value.contains(" "), let at = value.firstIndex(of: "@") else { return false }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        return !local.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    // MARK: Request and response

    /// The payload for a message and an optional email, with the device context.
    static func payload(message: String, email: String?, context: Context = .current()) -> Payload {
        let mail = email.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        return Payload(
            message: trimmed(message), email: mail, installID: context.installID,
            appVersion: context.appVersion.map { String($0.prefix(40)) },
            osVersion: context.osVersion.map { String($0.prefix(40)) },
            deviceModel: context.deviceModel.map { String($0.prefix(60)) },
            locale: context.locale.map { String($0.prefix(20)) })
    }

    func makeRequest(_ payload: Payload) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(payload)
        return request
    }

    /// 201 gives the row id; any other status maps to a `Failure`.
    static func parse(data: Data, response: URLResponse) -> Result<Int, Failure> {
        guard let http = response as? HTTPURLResponse else { return .failure(.network) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(http.statusCode) {
            return .success(json?["id"] as? Int ?? 0)
        }
        let code = json?["error"] as? String ?? ""
        switch (http.statusCode, code) {
        case (429, _), (_, "rate_limited"): return .failure(.rateLimited)
        case (_, "message_too_short"): return .failure(.messageTooShort)
        case (_, "message_too_long"): return .failure(.messageTooLong)
        case (_, "invalid_email"): return .failure(.invalidEmail)
        case (500..., _): return .failure(.server)
        default: return .failure(.rejected(code))
        }
    }

    /// Validates, sends and returns the new id.
    func send(message: String, email: String?, context: Context = .current()) async throws(Failure) -> Int {
        let text = Self.trimmed(message)
        guard Self.visibleCount(text) >= Self.minLength else { throw .messageTooShort }
        guard text.count <= Self.maxLength else { throw .messageTooLong }
        if let email, !Self.trimmed(email).isEmpty, !Self.isPlausibleEmail(email) { throw .invalidEmail }
        let request: URLRequest
        do {
            request = try makeRequest(Self.payload(message: text, email: email, context: context))
        } catch {
            throw .network
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw .network
        }
        return try Self.parse(data: data, response: response).get()
    }

    // MARK: Device context

    struct Context: Equatable, Sendable {
        var installID: String?
        var appVersion: String?
        var osVersion: String?
        var deviceModel: String?
        var locale: String?

        static func current(defaults: UserDefaults = .standard) -> Context {
            let info = Bundle.main.infoDictionary
            let short = info?["CFBundleShortVersionString"] as? String ?? ""
            let build = info?["CFBundleVersion"] as? String ?? ""
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return Context(
                installID: FeatureRequestClient.installID(defaults: defaults),
                appVersion: short.isEmpty ? nil : "\(short) (\(build))",
                osVersion: "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                deviceModel: FeatureRequestClient.deviceModel(),
                locale: Locale.current.identifier)
        }
    }

    /// A random id made once and kept, lowercase. It only groups ideas from the same install.
    static func installID(defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: installIDKey), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: installIDKey)
        return id
    }

    /// Machine id such as "iPhone17,1"; the simulated model on the simulator.
    static func deviceModel() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? nil : model
    }
}

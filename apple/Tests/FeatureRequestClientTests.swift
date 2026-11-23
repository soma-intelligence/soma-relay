import XCTest
@testable import SomaRelay

/// Request building and response parsing of the feature-request client. A fake transport answers;
/// nothing reaches the production endpoint.
final class FeatureRequestClientTests: XCTestCase {
    private let context = FeatureRequestClient.Context(
        installID: "0b8f4c1e-2f3a-4d5e-8f60-718293a4b5c6", appVersion: "1.0.0 (1)", osVersion: "iOS 26.1.0",
        deviceModel: "iPhone17,1", locale: "fr_FR")

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: FeatureRequestClient.defaultEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    // MARK: Request

    func testRequestIsAJSONPostWithAllFields() throws {
        let client = FeatureRequestClient()
        let payload = FeatureRequestClient.payload(message: "  Épingler une conversation  \n", email: " a@b.co ", context: context)
        let request = try client.makeRequest(payload)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://uchdtnhkkclhvnnqclht.supabase.co/functions/v1/feature-request")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try body(request)
        XCTAssertEqual(json["app"] as? String, "soma_relay")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["message"] as? String, "Épingler une conversation")
        XCTAssertEqual(json["email"] as? String, "a@b.co")
        XCTAssertEqual(json["install_id"] as? String, "0b8f4c1e-2f3a-4d5e-8f60-718293a4b5c6")
        XCTAssertEqual(json["app_version"] as? String, "1.0.0 (1)")
        XCTAssertEqual(json["os_version"] as? String, "iOS 26.1.0")
        XCTAssertEqual(json["device_model"] as? String, "iPhone17,1")
        XCTAssertEqual(json["locale"] as? String, "fr_FR")
    }

    func testEmptyEmailAndMissingContextAreLeftOut() throws {
        let payload = FeatureRequestClient.payload(message: "Une idée", email: "   ", context: .init())
        let json = try body(FeatureRequestClient().makeRequest(payload))
        XCTAssertEqual(Set(json.keys), ["app", "platform", "message"])
    }

    func testLongContextValuesAreCutToTheBackendLimits() {
        let long = String(repeating: "x", count: 100)
        let payload = FeatureRequestClient.payload(
            message: "Une idée", email: nil,
            context: .init(installID: nil, appVersion: long, osVersion: long, deviceModel: long, locale: long))
        XCTAssertEqual(payload.appVersion?.count, 40)
        XCTAssertEqual(payload.osVersion?.count, 40)
        XCTAssertEqual(payload.deviceModel?.count, 60)
        XCTAssertEqual(payload.locale?.count, 20)
    }

    func testInstallIDIsMadeOnceLowercase() {
        let suite = "feature-request-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FeatureRequestClient.installID(defaults: defaults)
        XCTAssertEqual(first, first.lowercased())
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(FeatureRequestClient.installID(defaults: defaults), first)
    }

    // MARK: Validation

    func testSendNeedsThreeNonSpaceCharacters() {
        XCTAssertFalse(FeatureRequestClient.canSend("  a b  "))
        XCTAssertFalse(FeatureRequestClient.canSend("\n\n  "))
        XCTAssertTrue(FeatureRequestClient.canSend(" abc "))
        XCTAssertTrue(FeatureRequestClient.canSend(String(repeating: "a", count: 4000)))
        XCTAssertFalse(FeatureRequestClient.canSend(String(repeating: "a", count: 4001)))
    }

    func testEmailCheck() {
        XCTAssertTrue(FeatureRequestClient.isPlausibleEmail("quentin@example.com"))
        XCTAssertFalse(FeatureRequestClient.isPlausibleEmail("quentin@example"))
        XCTAssertFalse(FeatureRequestClient.isPlausibleEmail("@example.com"))
        XCTAssertFalse(FeatureRequestClient.isPlausibleEmail("a b@example.com"))
    }

    // MARK: Responses

    func testParse() {
        func parse(_ status: Int, _ json: String) -> Result<Int, FeatureRequestClient.Failure> {
            FeatureRequestClient.parse(data: Data(json.utf8), response: Self.response(status))
        }
        XCTAssertEqual(parse(201, #"{"id":42}"#), .success(42))
        XCTAssertEqual(parse(400, #"{"error":"message_too_short"}"#), .failure(.messageTooShort))
        XCTAssertEqual(parse(400, #"{"error":"message_too_long"}"#), .failure(.messageTooLong))
        XCTAssertEqual(parse(400, #"{"error":"invalid_email"}"#), .failure(.invalidEmail))
        XCTAssertEqual(parse(400, #"{"error":"invalid_platform"}"#), .failure(.rejected("invalid_platform")))
        XCTAssertEqual(parse(429, #"{"error":"rate_limited"}"#), .failure(.rateLimited))
        XCTAssertEqual(parse(500, #"{"error":"server_error"}"#), .failure(.server))
        XCTAssertEqual(parse(502, "<html>"), .failure(.server))
        XCTAssertEqual(FeatureRequestClient.parse(data: Data(), response: URLResponse()), .failure(.network))
    }

    func testRateLimitCopy() {
        XCTAssertEqual(FeatureRequestClient.Failure.rateLimited.message, "Trop d'idées en peu de temps. Réessaie dans une heure.")
    }

    // MARK: Send through a fake transport

    func testSendPostsOnceAndReturnsTheID() async throws {
        let seen = Recorder()
        let client = FeatureRequestClient(transport: { request in
            await seen.add(request)
            return (Data(#"{"id":7}"#.utf8), Self.response(201))
        })
        let id = try await client.send(message: "Une bonne idée", email: nil, context: context)
        XCTAssertEqual(id, 7)
        let requests = await seen.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try body(requests[0])["message"] as? String, "Une bonne idée")
    }

    func testSendMapsRateLimitAndNetworkErrors() async {
        let limited = FeatureRequestClient(transport: { _ in (Data(#"{"error":"rate_limited"}"#.utf8), Self.response(429)) })
        do {
            _ = try await limited.send(message: "Une idée", email: nil, context: context)
            XCTFail("expected rate limit")
        } catch {
            XCTAssertEqual(error, .rateLimited)
        }
        let offline = FeatureRequestClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await offline.send(message: "Une idée", email: nil, context: context)
            XCTFail("expected network error")
        } catch {
            XCTAssertEqual(error, .network)
        }
    }

    func testSendRejectsBadInputBeforeTheNetwork() async {
        let seen = Recorder()
        let client = FeatureRequestClient(transport: { request in
            await seen.add(request)
            return (Data(), Self.response(201))
        })
        do {
            _ = try await client.send(message: " a ", email: nil, context: context)
            XCTFail("expected too short")
        } catch {
            XCTAssertEqual(error, .messageTooShort)
        }
        do {
            _ = try await client.send(message: "Une idée", email: "pas-un-mail", context: context)
            XCTFail("expected invalid email")
        } catch {
            XCTAssertEqual(error, .invalidEmail)
        }
        let count = await seen.requests.count
        XCTAssertEqual(count, 0)
    }
}

private actor Recorder {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
}

import XCTest
@testable import ClaudeLimitsCore

final class UsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_288_000)
    func parse(_ json: String) throws -> UsageSnapshot { try UsageParser.parse(Data(json.utf8), now: now) }

    func testModernFableAndSharedOpus() throws {
        let value = try parse("""
        {"five_hour":{"utilization":17,"resets_at":"2026-10-08T01:00:00Z"},
        "seven_day":{"utilization":30,"resets_at":"2026-10-12T01:00:00.000Z"},
        "seven_day_opus":null,"limits":[{"kind":"weekly_scoped","percent":45,
        "resets_at":"2026-10-12T01:00:00Z","scope":{"model":{"display_name":"Fable"}}}]}
        """)
        XCTAssertEqual(value.title(at: now), "F 55% · O 70% · 5 83%")
        XCTAssertTrue(value.opusUsesSharedWeek)
        XCTAssertNotNil(value.fable?.resetsAt)
    }

    func testExplicitOpusOverridesSharedWeek() throws {
        let value = try parse("""
        {"seven_day":{"utilization":30},"seven_day_opus":{"utilization":80},
        "seven_day_fable":{"utilization":100},"five_hour":{"utilization":0}}
        """)
        XCTAssertEqual(value.title(at: now), "F 0% · O 20% · 5 100%")
        XCTAssertFalse(value.opusUsesSharedWeek)
    }

    func testScopedOpusAndFableTakePrecedence() throws {
        let value = try parse("""
        {"seven_day_opus":{"utilization":1},"seven_day_fable":{"utilization":1},
        "limits":[{"kind":"weekly_scoped","percent":40,"scope":{"model":{"display_name":"Opus"}}},
        {"kind":"weekly_scoped","percent":90,"scope":{"model":{"display_name":"fable"}}}]}
        """)
        XCTAssertEqual(value.title(at: now), "F 10% · O 60% · 5 —")
    }

    func testMissingBucketsAreUnavailableNotUnused() throws {
        let value = try parse("{\"five_hour\":{\"utilization\":22},\"seven_day\":null}")
        XCTAssertEqual(value.title(at: now), "F — · O — · 5 78%")
        XCTAssertNil(value.fable)
        for json in ["{}", "null", "[]", "{\"five_hour\":null}", "{\"error\":{},\"five_hour\":{\"utilization\":0}}"] {
            XCTAssertThrowsError(try parse(json))
        }
    }

    func testInvalidUtilizationAndResetAreRejected() {
        for raw in ["true", "\"12\"", "-1", "101", "null"] {
            XCTAssertThrowsError(try parse("{\"five_hour\":{\"utilization\":\(raw)}}"))
        }
        for json in ["{\"five_hour\":{}}", "{\"five_hour\":42}",
                     "{\"five_hour\":{\"utilization\":2,\"resets_at\":\"bad\"}}",
                     "{\"five_hour\":{\"utilization\":2,\"resets_at\":42}}"] {
            XCTAssertThrowsError(try parse(json))
        }
    }

    func testScopeCannotMasqueradeAsAnotherModel() throws {
        let value = try parse("""
        {"five_hour":{"utilization":50},"limits":[
        {"kind":"weekly_scoped","percent":1,"scope":{"model":{"display_name":"Fable impostor"}}},
        {"kind":"other","percent":2,"scope":{"model":{"display_name":"Opus"}}}]}
        """)
        XCTAssertEqual(value.title(at: now), "F — · O — · 5 50%")
        XCTAssertThrowsError(try parse("""
        {"limits":[{"kind":"weekly_scoped","percent":1,"scope":{"model":{"display_name":"Fable"}}},
        {"kind":"weekly_scoped","percent":2,"scope":{"model":{"display_name":"Fable"}}}]}
        """))
    }

    func testRoundingNeverOverstatesRemainingBudget() throws {
        XCTAssertEqual(try parse("{\"five_hour\":{\"utilization\":99.1}}").fiveHour?.percent, "0%")
        XCTAssertEqual(try parse("{\"five_hour\":{\"utilization\":20.1}}").fiveHour?.percent, "79%")
    }

    func testOldFailedAndResetWindowsDoNotShowLivePercentages() throws {
        let value = try parse("{\"five_hour\":{\"utilization\":20,\"resets_at\":\"2020-01-01T00:00:00Z\"},\"seven_day\":{\"utilization\":10}}")
        XCTAssertEqual(value.title(at: now), "F — · O 90% · 5 —")
        XCTAssertEqual(value.title(at: now, failed: true), "F — · O — · 5 —")
        XCTAssertEqual(value.title(at: now.addingTimeInterval(301)), "F — · O — · 5 —")
    }

    func testCredentialValidation() throws {
        let fixture = "{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\",\"expiresAt\":0}}"
        XCTAssertEqual(try ClaudeCredential.decode(Data(fixture.utf8), now: now).token, "fixture-token")
        for value in ["{}", "{\"claudeAiOauth\":{}}",
                      "{\"claudeAiOauth\":{\"accessToken\":\"\"}}",
                      "{\"claudeAiOauth\":{\"accessToken\":\"bad token\"}}",
                      "{\"claudeAiOauth\":{\"accessToken\":\"fixture\",\"expiresAt\":1}}"] {
            XCTAssertThrowsError(try ClaudeCredential.decode(Data(value.utf8), now: now))
        }
    }

    func testRetryAfterSecondsAndDate() {
        XCTAssertEqual(UsageClient.retryDelay("700", now: now), 700)
        XCTAssertEqual(UsageClient.retryDelay("1", now: now), 120)
        XCTAssertEqual(UsageClient.retryDelay("nan", now: now), 300)
        XCTAssertEqual(UsageClient.retryDelay(nil, now: now), 300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(UsageClient.retryDelay(formatter.string(from: now.addingTimeInterval(600)), now: now), 600)
    }
}

private final class MockFetcher: UsageFetching {
    var outcome: Result<UsageSnapshot, UsageError>
    var calls = 0
    var delay: UInt64 = 0
    init(_ outcome: Result<UsageSnapshot, UsageError>) { self.outcome = outcome }
    func fetch() async throws -> UsageSnapshot {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return try outcome.get()
    }
}

final class MonitorTests: XCTestCase {
    @MainActor func testFailureHidesStalePercentagesAndRecoveryUpdates() async throws {
        let sample = try UsageParser.parse(Data("{\"five_hour\":{\"utilization\":25}}".utf8))
        let client = MockFetcher(.success(sample)), model = UsageMonitor(client: MockFetcher(.success(sample)))
        await model.refresh()
        XCTAssertEqual(model.title, "F — · O — · 5 75%")
        let monitored = UsageMonitor(client: client)
        await monitored.refresh()
        client.outcome = .failure(.network)
        await monitored.refresh(manual: true)
        XCTAssertEqual(monitored.title, "F — · O — · 5 —")
        XCTAssertNotNil(monitored.snapshot)
        client.outcome = .failure(.loginRequired)
        await monitored.refresh(manual: true)
        XCTAssertNil(monitored.snapshot)
        client.outcome = .success(sample)
        await monitored.refresh(manual: true)
        XCTAssertNil(monitored.error)
        XCTAssertEqual(monitored.title, "F — · O — · 5 75%")
    }

    @MainActor func testRateLimitBackoffAlsoAppliesToManualRefresh() async {
        var now = Date()
        let client = MockFetcher(.failure(.rateLimited(600)))
        let model = UsageMonitor(client: client, clock: { now })
        await model.refresh()
        await model.refresh(manual: true)
        XCTAssertEqual(client.calls, 1)
        now = now.addingTimeInterval(601)
        await model.refresh()
        XCTAssertEqual(client.calls, 2)
    }

    @MainActor func testRefreshesDoNotOverlap() async {
        let client = MockFetcher(.failure(.network)); client.delay = 100_000_000
        let model = UsageMonitor(client: client)
        let first = Task { await model.refresh() }
        await Task.yield()
        await model.refresh(manual: true)
        await first.value
        XCTAssertEqual(client.calls, 1)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var code = 200
    static var body = Data()
    static var requestSeen: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestSeen = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Retry-After": "800"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClientTests: XCTestCase {
    func client() -> UsageClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return UsageClient(session: URLSession(configuration: config), credential: {
            try ClaudeCredential.decode(Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\"}}".utf8))
        })
    }

    func testRequestUsesUsageOnlyAndParsesRealSchema() async throws {
        MockURLProtocol.code = 200; MockURLProtocol.body = Data("{\"five_hour\":{\"utilization\":8}}".utf8)
        let sample = try await client().fetch()
        XCTAssertEqual(sample.fiveHour?.percent, "92%")
        XCTAssertEqual(MockURLProtocol.requestSeen?.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(MockURLProtocol.requestSeen?.httpMethod, "GET")
        XCTAssertEqual(MockURLProtocol.requestSeen?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertNil(MockURLProtocol.requestSeen?.httpBody)
    }

    func testHTTPFailuresAreTypedAndBodiesNeverBecomeErrors() async {
        for (code, expected) in [(401, UsageError.loginRequired), (403, .loginRequired),
                                 (429, .rateLimited(800)), (500, .unavailable(500)), (302, .unavailable(302))] {
            MockURLProtocol.code = code; MockURLProtocol.body = Data("private response must not be logged".utf8)
            do { _ = try await client().fetch(); XCTFail("Expected HTTP failure") }
            catch { XCTAssertEqual(error as? UsageError, expected) }
        }
    }
}

import Foundation
import XCTest
@testable import VibeToken

final class Sub2APIClientTests: XCTestCase {
    func testLoginStoresOnlyAuthenticatedAdminSession() async throws {
        let loader = StubLoader(responses: [
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer","user":{"role":"admin"}}}"#
            )
        ])
        let store = MemorySessionStore()
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        let result = try await client.login(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            email: "admin@example.com",
            password: "not-stored"
        )

        guard case .authenticated = result else { return XCTFail("Expected authenticated result") }
        XCTAssertEqual(try store.load()?.accessToken, "access")
        let capturedRequests = await loader.requests()
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("not-stored") == true)
    }

    func testLoginKeepsTwoFactorTempTokenInMemoryWithoutSavingSession() async throws {
        let loader = StubLoader(responses: [
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"requires_2fa":true,"temp_token":"temporary","user_email_masked":"a***@example.com"}}"#
            )
        ])
        let store = MemorySessionStore()
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        let result = try await client.login(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            email: "admin@example.com",
            password: "password"
        )

        XCTAssertEqual(
            result,
            .requiresTwoFactor(tempToken: "temporary", maskedEmail: "a***@example.com")
        )
        XCTAssertNil(try store.load())
    }

    func testFetchAccountsRefreshesExpiredAuthorizationOnceAndKeepsPaginationBounded() async throws {
        let loader = StubLoader(responses: [
            response(status: 401, body: #"{"code":401,"message":"expired"}"#),
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}}"#
            ),
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"items":[{"id":7,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"pro"},"extra":{"codex_5h_used_percent":25,"codex_7d_used_percent":50,"codex_usage_updated_at":"2026-08-06T00:00:00Z"}}],"total":1,"page":1,"page_size":100,"pages":1}}"#
            )
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "old-access", refreshToken: "refresh", expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        let accounts = try await client.fetchAccounts(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            pageSize: 100,
            maximumPages: 2
        )

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].snapshot(now: Date()).fiveHourUsedPercent, 25)
        XCTAssertEqual(try store.load()?.accessToken, "new-access")
        let requests = await loader.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    func testLegacyPrimaryAndSecondaryWindowsAreMappedByDuration() throws {
        let body = #"{"id":8,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"pro"},"extra":{"codex_primary_used_percent":70,"codex_primary_reset_after_seconds":100,"codex_primary_window_minutes":10080,"codex_secondary_used_percent":25,"codex_secondary_reset_after_seconds":50,"codex_secondary_window_minutes":300,"codex_usage_updated_at":"2026-08-06T00:00:00Z"}}"#
        let payload = try JSONDecoder().decode(Sub2APIAccountPayload.self, from: Data(body.utf8))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = payload.snapshot(now: now)

        XCTAssertEqual(snapshot.fiveHourUsedPercent, 25)
        XCTAssertEqual(snapshot.sevenDayUsedPercent, 70)
        XCTAssertEqual(snapshot.fiveHourResetAt, now.addingTimeInterval(50))
        XCTAssertEqual(snapshot.sevenDayResetAt, now.addingTimeInterval(100))
    }

    func testOfficialRuntimeAccountStatusFieldsAreMapped() throws {
        let body = #"{"id":9,"status":"active","schedulable":false,"rate_limit_reset_at":"2026-08-06T01:00:00Z","overload_until":"2026-08-06T02:00:00Z","temp_unschedulable_until":"2026-08-06T03:00:00Z"}"#
        let payload = try JSONDecoder().decode(Sub2APIAccountPayload.self, from: Data(body.utf8))
        let snapshot = payload.snapshot(now: Date())

        XCTAssertEqual(snapshot.rateLimitResetAt, ISO8601DateFormatter().date(from: "2026-08-06T01:00:00Z"))
        XCTAssertEqual(snapshot.overloadUntil, ISO8601DateFormatter().date(from: "2026-08-06T02:00:00Z"))
        XCTAssertEqual(
            snapshot.tempUnschedulableUntil,
            ISO8601DateFormatter().date(from: "2026-08-06T03:00:00Z")
        )
    }

    func testDetectedProAccountHasNoDefaultCapacityTier() throws {
        let body = #"{"id":10,"name":"Primary","status":"active","schedulable":true,"credentials":{"plan_type":"pro"}}"#
        let payload = try JSONDecoder().decode(Sub2APIAccountPayload.self, from: Data(body.utf8))
        let snapshot = payload.snapshot(now: Date())

        XCTAssertEqual(payload.capacityDisplayName, "Primary")
        XCTAssertEqual(payload.detectedPlan, "Pro")
        XCTAssertNil(snapshot.capacityTier)
    }

    func testFetchAccountsDeduplicatesIDsAcrossMovingPages() async throws {
        let loader = StubLoader(responses: [
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"items":[{"id":1,"status":"active","schedulable":true,"parent_account_id":null},{"id":2,"status":"active","schedulable":true,"parent_account_id":null}],"total":3,"page":1,"page_size":2,"pages":2}}"#
            ),
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"items":[{"id":2,"status":"active","schedulable":true,"parent_account_id":null},{"id":3,"status":"active","schedulable":true,"parent_account_id":null}],"total":3,"page":2,"page_size":2,"pages":2}}"#
            )
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        let accounts = try await client.fetchAccounts(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            pageSize: 2,
            maximumPages: 2
        )

        XCTAssertEqual(accounts.map(\.id), [1, 2, 3])
    }

    func testDynamicOptionalAccountFieldsDoNotRejectEntirePage() async throws {
        let loader = StubLoader(responses: [
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"items":[{"id":1,"status":"active","schedulable":true,"parent_account_id":"9","credentials":{"plan_type":"team"},"extra":{"codex_5h_used_percent":"25.5","codex_7d_used_percent":40,"codex_5h_reset_at":1800000000}},{"id":2,"status":"active","schedulable":true,"credentials":"redacted","extra":[]}],"total":2,"page":1,"page_size":100,"pages":1}}"#
            )
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        let accounts = try await client.fetchAccounts(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            pageSize: 100,
            maximumPages: 1
        )
        let first = accounts[0].snapshot(now: Date())
        let second = accounts[1].snapshot(now: Date())

        XCTAssertEqual(first.parentAccountID, 9)
        XCTAssertEqual(first.plan, "Team")
        XCTAssertEqual(first.fiveHourUsedPercent, 25.5)
        XCTAssertEqual(first.sevenDayUsedPercent, 40)
        XCTAssertEqual(first.fiveHourResetAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(second.plan, "Unknown")
        XCTAssertNil(second.fiveHourUsedPercent)
    }

    private func response(status: Int, body: String) -> StubLoader.Response {
        StubLoader.Response(status: status, data: Data(body.utf8))
    }
}

private actor StubLoader: Sub2APIHTTPDataLoading {
    struct Response: Sendable {
        let status: Int
        let data: Data
    }

    private var queued: [Response]
    private var captured: [URLRequest] = []

    init(responses: [Response]) {
        queued = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured.append(request)
        guard !queued.isEmpty else { throw URLError(.badServerResponse) }
        let next = queued.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (next.data, response)
    }

    func requests() -> [URLRequest] { captured }
}

private final class MemorySessionStore: Sub2APISessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: Sub2APISession?

    init(session: Sub2APISession? = nil) {
        self.session = session
    }

    func load() throws -> Sub2APISession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func save(_ session: Sub2APISession) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }
}

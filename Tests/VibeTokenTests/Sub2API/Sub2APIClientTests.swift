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

    func testRefreshAccountUsagePostsNormalizedIDsWithForcedProbe() async throws {
        let loader = StubLoader(responses: [
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"usage":{"2":{"source":"active"},"7":{"source":"active"}},"errors":{}}}"#
            )
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        try await client.refreshAccountUsage(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            accountIDs: [7, 2, 7, 0, -1]
        )

        let requests = await loader.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/admin/accounts/usage/batch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["account_ids"] as? [Int], [2, 7])
        XCTAssertEqual(payload["force"] as? Bool, true)
    }

    func testBatchUsageErrorsFailTheWholeRefresh() async throws {
        let loader = StubLoader(responses: [
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"usage":{"2":{"source":"active"}},"errors":{"7":{"message":"probe failed"}}}}"#
            )
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        do {
            try await client.refreshAccountUsage(
                baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
                accountIDs: [2, 7]
            )
            XCTFail("Expected incomplete usage refresh")
        } catch let error as Sub2APIError {
            XCTAssertEqual(error, .usageRefreshIncomplete(refreshed: 1, total: 2))
        }
    }

    func testRefreshAccountUsageRefreshesExpiredAuthorizationOnce() async throws {
        let loader = StubLoader(responses: [
            response(status: 401, body: #"{"code":401,"message":"expired"}"#),
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}}"#
            ),
            response(status: 200, body: #"{"code":0,"message":"success","data":{}}"#)
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(
                accessToken: "old-access",
                refreshToken: "refresh",
                expiresAt: nil
            )
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        try await client.refreshAccountUsage(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            accountIDs: [4]
        )

        let requests = await loader.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(requests[1].url?.path, "/api/v1/auth/refresh")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[2].url?.path, "/api/v1/admin/accounts/usage/batch")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(try store.load()?.accessToken, "new-access")
    }

    func testNonJSONNotFoundIsClassifiedAsIncompatibleServerBeforeDecoding() async throws {
        let loader = StubLoader(responses: [
            response(status: 404, body: "Not Found")
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        do {
            _ = try await client.fetchAccounts(
                baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
                pageSize: 100,
                maximumPages: 1
            )
            XCTFail("Expected incompatible server")
        } catch let error as Sub2APIError {
            XCTAssertEqual(error, .incompatibleServer)
        }
    }

    func testRefreshAccountUsageFallsBackToReleasedPerAccountEndpoint() async throws {
        let loader = StubLoader(responses: [
            response(status: 404, body: "Not Found"),
            response(status: 200, body: usageResponse),
            response(status: 200, body: usageResponse)
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        try await client.refreshAccountUsage(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            accountIDs: [7, 2]
        )

        let requests = await loader.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/api/v1/admin/accounts/usage/batch")

        let fallbackRequests = Array(requests.dropFirst())
        XCTAssertEqual(
            Set(fallbackRequests.compactMap(\.url?.path)),
            Set(["/api/v1/admin/accounts/2/usage", "/api/v1/admin/accounts/7/usage"])
        )
        for request in fallbackRequests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(
                queryItems,
                [
                    URLQueryItem(name: "source", value: "active"),
                    URLQueryItem(name: "force", value: "true")
                ]
            )
        }
    }

    func testPerAccountFallbackRefreshesAuthorizationOnlyOnce() async throws {
        let loader = StubLoader(responses: [
            response(status: 404, body: "Not Found"),
            response(status: 401, body: #"{"code":401,"message":"expired"}"#),
            response(
                status: 200,
                body: #"{"code":0,"message":"success","data":{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}}"#
            ),
            response(status: 200, body: usageResponse)
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(
                accessToken: "old-access",
                refreshToken: "refresh",
                expiresAt: nil
            )
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        try await client.refreshAccountUsage(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            accountIDs: [4]
        )

        let requests = await loader.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/v1/auth/refresh" }.count, 1)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    func testPerAccountFallbackFailsWholeRefreshWhenOneAccountFails() async throws {
        let loader = StubLoader(responses: [
            response(status: 404, body: "Not Found"),
            response(status: 500, body: #"{"code":500,"message":"probe failed"}"#),
            response(status: 200, body: usageResponse)
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        do {
            try await client.refreshAccountUsage(
                baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
                accountIDs: [1, 2]
            )
            XCTFail("Expected incomplete usage refresh")
        } catch let error as Sub2APIError {
            XCTAssertEqual(error, .usageRefreshIncomplete(refreshed: 1, total: 2))
        }

        let requests = await loader.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.dropFirst().compactMap(\.url?.path)), Set([
            "/api/v1/admin/accounts/1/usage",
            "/api/v1/admin/accounts/2/usage"
        ]))
    }

    func testMissingPerAccountEndpointRemainsIncompatible() async throws {
        let loader = StubLoader(responses: [
            response(status: 404, body: "Not Found"),
            response(status: 404, body: "Not Found")
        ])
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        do {
            try await client.refreshAccountUsage(
                baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
                accountIDs: [4]
            )
            XCTFail("Expected incompatible server")
        } catch let error as Sub2APIError {
            XCTAssertEqual(error, .incompatibleServer)
        }

        let requests = await loader.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.url?.path, "/api/v1/admin/accounts/4/usage")
    }

    func testPerAccountFallbackLimitsConcurrentRequestsToSix() async throws {
        let loader = StubLoader(
            responses: [
                response(status: 404, body: "Not Found"),
                response(status: 200, body: usageResponse),
                response(status: 200, body: usageResponse),
                response(status: 200, body: usageResponse),
                response(status: 200, body: usageResponse),
                response(status: 200, body: usageResponse),
                response(status: 200, body: usageResponse),
                response(status: 200, body: usageResponse)
            ],
            responseDelayNanoseconds: 50_000_000
        )
        let store = MemorySessionStore(
            session: Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil)
        )
        let client = Sub2APIClient(loader: loader, sessionStore: store, requestTimeout: 2)

        try await client.refreshAccountUsage(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            accountIDs: Array(1...7)
        )

        let peakRequests = await loader.peakConcurrentRequests()
        XCTAssertEqual(peakRequests, 6)
    }

    private var usageResponse: String {
        #"{"code":0,"message":"success","data":{"source":"active"}}"#
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
    private let responseDelayNanoseconds: UInt64
    private var activeRequests = 0
    private var peakRequests = 0

    init(responses: [Response], responseDelayNanoseconds: UInt64 = 0) {
        queued = responses
        self.responseDelayNanoseconds = responseDelayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured.append(request)
        activeRequests += 1
        peakRequests = max(peakRequests, activeRequests)
        defer { activeRequests -= 1 }
        if responseDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: responseDelayNanoseconds)
        }
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

    func peakConcurrentRequests() -> Int { peakRequests }
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

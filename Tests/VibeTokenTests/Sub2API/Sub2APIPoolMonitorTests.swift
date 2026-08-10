import Foundation
import XCTest
@testable import VibeToken

final class Sub2APIPoolMonitorTests: XCTestCase {
    func testCapacitySelectionsPersistAndShadowAccountsAreNotConfigurable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeTokenMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseURL = try XCTUnwrap(URL(string: "https://relay.example.com/api/v1"))
        let sessionStore = FileSub2APISessionStore(supportDirectory: directory)
        let connectionStore = FileSub2APIConnectionStore(supportDirectory: directory)
        let capacityStore = FileSub2APICapacityConfigurationStore(supportDirectory: directory)
        try sessionStore.save(Sub2APISession(accessToken: "test", refreshToken: nil, expiresAt: nil))
        try connectionStore.save(Sub2APIConnection(baseURL: baseURL, email: "admin@example.com"))

        let payloads = try decodeAccounts()
        let firstMonitor = makeMonitor(
            client: FixedAccountsClient(accounts: payloads),
            sessionStore: sessionStore,
            connectionStore: connectionStore,
            capacityStore: capacityStore
        )
        let initial = try await firstMonitor.refresh(force: true)
        let initialOptions = try await firstMonitor.capacityOptions()

        XCTAssertEqual(initial?.totalCapacityAccounts, 3)
        XCTAssertEqual(initial?.totalCapacityWeight, 1)
        XCTAssertEqual(initial?.unconfiguredCapacityAccounts, 2)
        XCTAssertNil(initial?.displayedRemainingFraction)
        XCTAssertEqual(initialOptions.map(\.accountID), [1, 2, 4])
        XCTAssertEqual(initialOptions.map(\.selectedTier), [nil, nil, .plus])
        XCTAssertEqual(initialOptions.map(\.detectedPlan), ["Pro", "Pro", "Plus"])

        do {
            _ = try await firstMonitor.saveCapacitySelections([
                Sub2APIAccountCapacitySelection(accountID: 1, tier: .pro20)
            ])
            XCTFail("Expected every Pro account to require a selection")
        } catch {
            XCTAssertEqual(error as? Sub2APIError, .capacityConfigurationIncomplete)
        }

        let updated = try await firstMonitor.saveCapacitySelections([
            Sub2APIAccountCapacitySelection(accountID: 1, tier: .pro10),
            Sub2APIAccountCapacitySelection(accountID: 2, tier: .pro5),
            Sub2APIAccountCapacitySelection(accountID: 3, tier: .pro20)
        ])
        XCTAssertEqual(updated?.totalCapacityWeight, 16)

        let restoredMonitor = makeMonitor(
            client: FixedAccountsClient(accounts: payloads),
            sessionStore: sessionStore,
            connectionStore: connectionStore,
            capacityStore: capacityStore
        )
        let restored = try await restoredMonitor.refresh(force: true)
        let restoredOptions = try await restoredMonitor.capacityOptions()

        XCTAssertEqual(restored?.totalCapacityWeight, 16)
        XCTAssertEqual(restoredOptions.map(\.selectedTier), [.pro10, .pro5, .plus])
        XCTAssertNil(
            try capacityStore.load()?
                .tiersByAccountID(serverIdentifier: baseURL.absoluteString)[3]
        )

        let monitorWithNewPro = makeMonitor(
            client: FixedAccountsClient(accounts: try decodeAccountsWithNewAccount(plan: "pro")),
            sessionStore: sessionStore,
            connectionStore: connectionStore,
            capacityStore: capacityStore
        )
        let snapshotWithNewPro = try await monitorWithNewPro.refresh(force: true)
        XCTAssertEqual(snapshotWithNewPro?.unconfiguredCapacityAccounts, 1)
        XCTAssertEqual(snapshotWithNewPro?.requiresCapacityConfiguration, true)
        XCTAssertNil(snapshotWithNewPro?.displayedRemainingFraction)

        let monitorWithNewPlus = makeMonitor(
            client: FixedAccountsClient(accounts: try decodeAccountsWithNewAccount(plan: "plus")),
            sessionStore: sessionStore,
            connectionStore: connectionStore,
            capacityStore: capacityStore
        )
        let snapshotWithNewPlus = try await monitorWithNewPlus.refresh(force: true)
        XCTAssertEqual(snapshotWithNewPlus?.unconfiguredCapacityAccounts, 0)
        XCTAssertEqual(snapshotWithNewPlus?.requiresCapacityConfiguration, false)
        XCTAssertEqual(snapshotWithNewPlus?.totalCapacityWeight, 17)

        let otherBaseURL = try XCTUnwrap(URL(string: "https://other-relay.example.com/api/v1"))
        try connectionStore.save(
            Sub2APIConnection(baseURL: otherBaseURL, email: "admin@example.com")
        )
        let otherServerMonitor = makeMonitor(
            client: FixedAccountsClient(accounts: payloads),
            sessionStore: sessionStore,
            connectionStore: connectionStore,
            capacityStore: capacityStore
        )
        let otherServerSnapshot = try await otherServerMonitor.refresh(force: true)
        let otherServerOptions = try await otherServerMonitor.capacityOptions()

        XCTAssertEqual(otherServerSnapshot?.totalCapacityWeight, 1)
        XCTAssertEqual(otherServerSnapshot?.unconfiguredCapacityAccounts, 2)
        XCTAssertEqual(otherServerOptions.map(\.selectedTier), [nil, nil, .plus])
    }

    func testInitialRefreshProbesActivePhysicalAccountsAndUsesRefetchedSnapshot() async throws {
        let oldTimestamp = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-60 * 60)
        )
        let freshTimestamp = ISO8601DateFormatter().string(from: Date())
        let beforeRefresh = try [
            decodeUsageAccount(id: 1, status: "active", updatedAt: oldTimestamp),
            decodeUsageAccount(id: 2, status: "inactive", updatedAt: oldTimestamp),
            decodeUsageAccount(id: 3, status: "active", parentAccountID: 1, updatedAt: oldTimestamp)
        ]
        let afterRefresh = try [
            decodeUsageAccount(id: 1, status: "active", updatedAt: freshTimestamp),
            decodeUsageAccount(id: 2, status: "inactive", updatedAt: oldTimestamp),
            decodeUsageAccount(id: 3, status: "active", parentAccountID: 1, updatedAt: oldTimestamp)
        ]
        let client = RecordingAccountsClient(accountResponses: [beforeRefresh, afterRefresh])
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let snapshot = try await fixture.monitor.refresh(force: true)
        let fetchCount = await client.fetchCount
        let usageRequests = await client.usageRequests

        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(usageRequests, [[1]])
        XCTAssertEqual(snapshot?.staleWindowAccounts, 0)
    }

    func testLightweightPollingDoesNotRepeatUsageRefreshWithinInterval() async throws {
        let currentTimestamp = ISO8601DateFormatter().string(from: Date())
        let accounts = try [decodeUsageAccount(id: 1, status: "active", updatedAt: currentTimestamp)]
        let client = RecordingAccountsClient(accountResponses: [accounts, accounts, accounts])
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.monitor.refresh(force: true)
        _ = try await fixture.monitor.refresh(force: false)
        let fetchCount = await client.fetchCount
        let usageRequests = await client.usageRequests

        XCTAssertEqual(fetchCount, 3)
        XCTAssertEqual(usageRequests, [[1]])
    }

    func testEveryForcedRefreshRunsAnOfficialUsageProbe() async throws {
        let firstTimestamp = ISO8601DateFormatter().string(from: Date())
        let secondTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        let thirdTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        let first = try [decodeUsageAccount(id: 1, status: "active", updatedAt: firstTimestamp)]
        let second = try [decodeUsageAccount(id: 1, status: "active", updatedAt: secondTimestamp)]
        let third = try [decodeUsageAccount(id: 1, status: "active", updatedAt: thirdTimestamp)]
        let client = RecordingAccountsClient(accountResponses: [first, second, second, third])
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.monitor.refresh(force: true)
        _ = try await fixture.monitor.refresh(force: true)

        let usageRequests = await client.usageRequests
        XCTAssertEqual(usageRequests, [[1], [1]])
    }

    func testUsageRefreshWaitsForAsynchronousPersistenceBeforePublishing() async throws {
        let oldTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let freshTimestamp = ISO8601DateFormatter().string(from: Date())
        let old = try [decodeUsageAccount(id: 1, status: "active", updatedAt: oldTimestamp)]
        let fresh = try [decodeUsageAccount(id: 1, status: "active", updatedAt: freshTimestamp)]
        let client = RecordingAccountsClient(accountResponses: [old, old, fresh])
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let snapshot = try await fixture.monitor.refresh(force: true)

        let fetchCount = await client.fetchCount
        XCTAssertEqual(fetchCount, 3)
        XCTAssertEqual(snapshot?.staleWindowAccounts, 0)
    }

    func testUsageRefreshDoesNotPublishWhenOneAccountTimestampDoesNotAdvance() async throws {
        let oldTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let freshTimestamp = ISO8601DateFormatter().string(from: Date())
        let baseline = try [
            decodeUsageAccount(id: 1, status: "active", updatedAt: oldTimestamp),
            decodeUsageAccount(id: 2, status: "active", updatedAt: oldTimestamp)
        ]
        let partial = try [
            decodeUsageAccount(id: 1, status: "active", updatedAt: freshTimestamp),
            decodeUsageAccount(id: 2, status: "active", updatedAt: oldTimestamp)
        ]
        let client = RecordingAccountsClient(accountResponses: [baseline, partial])
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.monitor.refresh(force: true)
            XCTFail("Expected incomplete usage refresh")
        } catch let error as Sub2APIError {
            XCTAssertEqual(error, .usageRefreshIncomplete(refreshed: 1, total: 2))
        }
    }

    func testExplicitlyRateLimitedAccountIsVerifiedAsZeroWithoutTimestampAdvance() async throws {
        let oldTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let baseline = try [decodeUsageAccount(id: 1, status: "active", updatedAt: oldTimestamp)]
        let limited = try [decodeLimitedUsageAccount(id: 1, updatedAt: oldTimestamp)]
        let client = RecordingAccountsClient(accountResponses: [baseline, limited])
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let snapshot = try await fixture.monitor.refresh(force: true)

        XCTAssertEqual(snapshot?.effectiveCapacity.availableAccounts, 0)
        XCTAssertEqual(snapshot?.effectiveCapacity.windowLimitedAccounts, 1)
        XCTAssertEqual(snapshot?.missingWindowAccounts, 0)
        XCTAssertEqual(snapshot?.staleWindowAccounts, 0)
    }

    func testUsageRefreshRetriesWhenActiveAccountSetChanges() async throws {
        let oldTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let freshTimestamp = ISO8601DateFormatter().string(from: Date())
        let oneAccount = try [decodeUsageAccount(id: 1, status: "active", updatedAt: oldTimestamp)]
        let changedPool = try [
            decodeUsageAccount(id: 1, status: "active", updatedAt: freshTimestamp),
            decodeUsageAccount(id: 2, status: "active", updatedAt: oldTimestamp)
        ]
        let fullyRefreshed = try [
            decodeUsageAccount(id: 1, status: "active", updatedAt: freshTimestamp),
            decodeUsageAccount(id: 2, status: "active", updatedAt: freshTimestamp)
        ]
        let client = RecordingAccountsClient(
            accountResponses: [oneAccount, changedPool, fullyRefreshed]
        )
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let snapshot = try await fixture.monitor.refresh(force: true)

        let usageRequests = await client.usageRequests
        XCTAssertEqual(usageRequests, [[1], [1, 2]])
        XCTAssertEqual(snapshot?.totalAccounts, 2)
    }

    func testIncompatibleUsageEndpointDoesNotPublishUnverifiedSnapshot() async throws {
        let accounts = try [decodeUsageAccount(id: 1, status: "active", updatedAt: nil)]
        let client = RecordingAccountsClient(
            accountResponses: [accounts],
            usageError: .incompatibleServer
        )
        let fixture = try makeUsageRefreshFixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.monitor.refresh(force: true)
            XCTFail("Expected incompatible server")
        } catch let error as Sub2APIError {
            XCTAssertEqual(error, .incompatibleServer)
        }
        let fetchCount = await client.fetchCount
        let usageRequests = await client.usageRequests

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(usageRequests, [[1]])
    }

    private func makeMonitor(
        client: FixedAccountsClient,
        sessionStore: FileSub2APISessionStore,
        connectionStore: FileSub2APIConnectionStore,
        capacityStore: FileSub2APICapacityConfigurationStore
    ) -> Sub2APIPoolMonitor {
        Sub2APIPoolMonitor(
            client: client,
            sessionStore: sessionStore,
            connectionStore: connectionStore,
            capacityConfigurationStore: capacityStore,
            pageSize: 100,
            maximumPages: 10,
            staleAfter: 900,
            minimumRefreshInterval: 30,
            usageRefreshInterval: 600
        )
    }

    private func decodeAccounts() throws -> [Sub2APIAccountPayload] {
        let currentTimestamp = ISO8601DateFormatter().string(from: Date())
        let body = #"""
        [
            {"id":1,"name":"Primary","status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"pro"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0,"codex_usage_updated_at":"\#(currentTimestamp)"}},
            {"id":2,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"pro"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0,"codex_usage_updated_at":"\#(currentTimestamp)"}},
            {"id":3,"status":"active","schedulable":true,"parent_account_id":1,"credentials":{"plan_type":"pro"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0,"codex_usage_updated_at":"\#(currentTimestamp)"}},
            {"id":4,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"plus"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0,"codex_usage_updated_at":"\#(currentTimestamp)"}}
        ]
        """#
        return try JSONDecoder().decode([Sub2APIAccountPayload].self, from: Data(body.utf8))
    }

    private func decodeAccountsWithNewAccount(
        plan: String
    ) throws -> [Sub2APIAccountPayload] {
        var accounts = try decodeAccounts()
        let currentTimestamp = ISO8601DateFormatter().string(from: Date())
        let body = #"""
        {"id":5,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"\#(plan)"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0,"codex_usage_updated_at":"\#(currentTimestamp)"}}
        """#
        accounts.append(
            try JSONDecoder().decode(Sub2APIAccountPayload.self, from: Data(body.utf8))
        )
        return accounts
    }

    private func decodeUsageAccount(
        id: Int64,
        status: String,
        parentAccountID: Int64? = nil,
        updatedAt: String?
    ) throws -> Sub2APIAccountPayload {
        var extra: [String: Any] = [
            "codex_5h_used_percent": 25,
            "codex_7d_used_percent": 50
        ]
        if let updatedAt {
            extra["codex_usage_updated_at"] = updatedAt
        }
        let parent: Any = parentAccountID.map { NSNumber(value: $0) } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": NSNumber(value: id),
            "status": status,
            "schedulable": true,
            "parent_account_id": parent,
            "credentials": ["plan_type": "plus"],
            "extra": extra
        ])
        return try JSONDecoder().decode(Sub2APIAccountPayload.self, from: data)
    }

    private func decodeLimitedUsageAccount(
        id: Int64,
        updatedAt: String
    ) throws -> Sub2APIAccountPayload {
        let resetAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60 * 60))
        let data = try JSONSerialization.data(withJSONObject: [
            "id": NSNumber(value: id),
            "status": "active",
            "schedulable": true,
            "parent_account_id": NSNull(),
            "rate_limit_reset_at": resetAt,
            "credentials": ["plan_type": "plus"],
            "extra": [
                "codex_5h_used_percent": 25,
                "codex_7d_used_percent": 50,
                "codex_usage_updated_at": updatedAt
            ]
        ])
        return try JSONDecoder().decode(Sub2APIAccountPayload.self, from: data)
    }

    private func makeUsageRefreshFixture(
        client: RecordingAccountsClient
    ) throws -> (monitor: Sub2APIPoolMonitor, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeTokenUsageRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseURL = try XCTUnwrap(URL(string: "https://relay.example.com/api/v1"))
        let sessionStore = FileSub2APISessionStore(supportDirectory: directory)
        let connectionStore = FileSub2APIConnectionStore(supportDirectory: directory)
        try sessionStore.save(Sub2APISession(accessToken: "test", refreshToken: nil, expiresAt: nil))
        try connectionStore.save(Sub2APIConnection(baseURL: baseURL, email: "admin@example.com"))
        return (
            Sub2APIPoolMonitor(
                client: client,
                sessionStore: sessionStore,
                connectionStore: connectionStore,
                capacityConfigurationStore: FileSub2APICapacityConfigurationStore(
                    supportDirectory: directory
                ),
                pageSize: 100,
                maximumPages: 10,
                staleAfter: 15 * 60,
                minimumRefreshInterval: 0,
                usageRefreshInterval: 10 * 60,
                usageReadbackAttempts: 3,
                usageReadbackDelay: .milliseconds(1)
            ),
            directory
        )
    }
}

private actor FixedAccountsClient: Sub2APIClientServing {
    let accounts: [Sub2APIAccountPayload]

    init(accounts: [Sub2APIAccountPayload]) {
        self.accounts = accounts
    }

    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult {
        throw Sub2APIError.serverUnavailable
    }

    func completeTwoFactor(
        baseURL: URL,
        tempToken: String,
        code: String
    ) async throws -> Sub2APISession {
        throw Sub2APIError.serverUnavailable
    }

    func fetchAccounts(
        baseURL: URL,
        pageSize: Int,
        maximumPages: Int
    ) async throws -> [Sub2APIAccountPayload] {
        accounts
    }

    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws {}
}

private actor RecordingAccountsClient: Sub2APIClientServing {
    private var accountResponses: [[Sub2APIAccountPayload]]
    private let fallbackAccounts: [Sub2APIAccountPayload]
    private let usageError: Sub2APIError?
    private(set) var fetchCount = 0
    private(set) var usageRequests: [[Int64]] = []

    init(
        accountResponses: [[Sub2APIAccountPayload]],
        usageError: Sub2APIError? = nil
    ) {
        self.accountResponses = accountResponses
        fallbackAccounts = accountResponses.last ?? []
        self.usageError = usageError
    }

    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult {
        throw Sub2APIError.serverUnavailable
    }

    func completeTwoFactor(
        baseURL: URL,
        tempToken: String,
        code: String
    ) async throws -> Sub2APISession {
        throw Sub2APIError.serverUnavailable
    }

    func fetchAccounts(
        baseURL: URL,
        pageSize: Int,
        maximumPages: Int
    ) async throws -> [Sub2APIAccountPayload] {
        fetchCount += 1
        guard !accountResponses.isEmpty else { return fallbackAccounts }
        return accountResponses.removeFirst()
    }

    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws {
        usageRequests.append(accountIDs)
        if let usageError { throw usageError }
    }
}

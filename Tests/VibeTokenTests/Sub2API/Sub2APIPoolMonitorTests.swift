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
            minimumRefreshInterval: 30
        )
    }

    private func decodeAccounts() throws -> [Sub2APIAccountPayload] {
        let body = #"""
        [
            {"id":1,"name":"Primary","status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"pro"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0}},
            {"id":2,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"pro"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0}},
            {"id":3,"status":"active","schedulable":true,"parent_account_id":1,"credentials":{"plan_type":"pro"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0}},
            {"id":4,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"plus"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0}}
        ]
        """#
        return try JSONDecoder().decode([Sub2APIAccountPayload].self, from: Data(body.utf8))
    }

    private func decodeAccountsWithNewAccount(
        plan: String
    ) throws -> [Sub2APIAccountPayload] {
        var accounts = try decodeAccounts()
        let body = #"""
        {"id":5,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"\#(plan)"},"extra":{"codex_5h_used_percent":0,"codex_7d_used_percent":0}}
        """#
        accounts.append(
            try JSONDecoder().decode(Sub2APIAccountPayload.self, from: Data(body.utf8))
        )
        return accounts
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
}

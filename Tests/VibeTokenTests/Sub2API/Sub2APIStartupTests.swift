import Foundation
import XCTest
@testable import VibeToken

@MainActor
final class Sub2APIStartupTests: XCTestCase {
    func testSub2APIRefreshDefaultsMatchOfficialCadence() {
        let configuration = makeTestConfiguration(
            dataRoot: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(configuration.sub2APISnapshotStaleSeconds, 8 * 60 * 60)
        XCTAssertEqual(configuration.sub2APIMinimumRefreshSeconds, 30)
        XCTAssertEqual(configuration.sub2APIPollingInterval, .seconds(30))
        XCTAssertEqual(configuration.sub2APIUsageRefreshIntervalSeconds, 30 * 60)
    }

    func testFirstRefreshRestoresSavedSub2APIConnection() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let connection = Sub2APIConnection(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            email: "admin@example.com"
        )
        let session = Sub2APISession(
            accessToken: "stored-access-token",
            refreshToken: "stored-refresh-token",
            expiresAt: nil
        )
        let sessionStore = CountingSessionStore(session: session)
        let connectionStore = CountingConnectionStore(connection: connection)
        let capacityConfigurationStore = MemoryCapacityConfigurationStore()
        let poolMonitor = Sub2APIPoolMonitor(
            client: UnusedSub2APIClient(),
            sessionStore: sessionStore,
            connectionStore: connectionStore,
            capacityConfigurationStore: capacityConfigurationStore,
            pageSize: 100,
            maximumPages: 100,
            staleAfter: 15 * 60,
            minimumRefreshInterval: 30,
            usageRefreshInterval: 10 * 60
        )
        let configuration = AppConfiguration(
            codexHome: codexHome,
            applicationSupportDirectory: codexHome,
            refreshInterval: .seconds(5),
            fileEventDebounceMilliseconds: 100,
            maximumTailBytes: 1_024,
            ingestionChunkBytes: 1_024,
            maximumJSONLineBytes: 1_024,
            historyLookbackDays: 30,
            maximumWatchedSessionFiles: 64,
            maximumUsageSourceFiles: 1_000,
            maximumStructuredUsageFileBytes: 1_024 * 1_024,
            additionalCodexHomes: []
        )
        let repository = UsageRepository(database: database)
        let codexAdapter = CodexUsageAdapter(
            configuration: configuration,
            repository: repository
        )
        let state = AppState(
            ingestionCoordinator: UsageIngestionCoordinator(
                sources: [codexAdapter],
                repository: repository,
                maximumWatchFiles: configuration.maximumWatchedSessionFiles
            ),
            sub2APIPoolMonitor: poolMonitor,
            refreshInterval: .seconds(5),
            sub2APIRefreshInterval: .seconds(30),
            fileEventDebounceMilliseconds: 100,
            costEstimator: CostEstimator(catalog: .officialAPI)
        )

        let didRefresh = await state.refresh(forceRemote: true)
        XCTAssertTrue(didRefresh)
        XCTAssertEqual(connectionStore.loadCount, 1)
        XCTAssertEqual(sessionStore.loadCount, 1)
        XCTAssertEqual(state.sub2APIStatus, .connected)
        XCTAssertEqual(state.sub2APIConnection, connection)

        let restoredConnection = await poolMonitor.savedConnection()
        XCTAssertEqual(restoredConnection, connection)
        XCTAssertEqual(connectionStore.loadCount, 1)
        XCTAssertEqual(sessionStore.loadCount, 1)
    }

    func testSub2APIPollingContinuesWhenUsageRefreshModeIsManual() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let connection = Sub2APIConnection(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            email: "admin@example.com"
        )
        let client = CountingSub2APIClient()
        let poolMonitor = Sub2APIPoolMonitor(
            client: client,
            sessionStore: CountingSessionStore(
                session: Sub2APISession(accessToken: "test", refreshToken: nil, expiresAt: nil)
            ),
            connectionStore: CountingConnectionStore(connection: connection),
            capacityConfigurationStore: MemoryCapacityConfigurationStore(),
            pageSize: 100,
            maximumPages: 100,
            staleAfter: 15 * 60,
            minimumRefreshInterval: 0,
            usageRefreshInterval: 10 * 60
        )
        let repository = UsageRepository(database: database)
        let state = AppState(
            ingestionCoordinator: UsageIngestionCoordinator(
                sources: [],
                repository: repository,
                maximumWatchFiles: 64
            ),
            sub2APIPoolMonitor: poolMonitor,
            refreshInterval: .seconds(30),
            sub2APIRefreshInterval: .milliseconds(20),
            fileEventDebounceMilliseconds: 100,
            costEstimator: CostEstimator(catalog: .officialAPI)
        )
        state.refreshMode = .manual

        state.startMonitoring()
        try await Task.sleep(for: .milliseconds(90))
        state.stopMonitoring()

        // 取消任务不会同步等待已在途的 actor 调用返回。
        try await Task.sleep(for: .milliseconds(50))
        let fetchCountAfterStop = await client.fetchCount
        XCTAssertGreaterThanOrEqual(fetchCountAfterStop, 2)
        try await Task.sleep(for: .milliseconds(50))
        let finalFetchCount = await client.fetchCount
        XCTAssertEqual(finalFetchCount, fetchCountAfterStop)
    }

    func testForcedRefreshRequestedWhileBackgroundRefreshIsBusyRunsTrailingProbe() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let connection = Sub2APIConnection(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            email: "admin@example.com"
        )
        let client = DelayedUsageSub2APIClient()
        let poolMonitor = Sub2APIPoolMonitor(
            client: client,
            sessionStore: CountingSessionStore(
                session: Sub2APISession(accessToken: "test", refreshToken: nil, expiresAt: nil)
            ),
            connectionStore: CountingConnectionStore(connection: connection),
            capacityConfigurationStore: MemoryCapacityConfigurationStore(),
            pageSize: 100,
            maximumPages: 100,
            staleAfter: 15 * 60,
            minimumRefreshInterval: 0,
            usageRefreshInterval: 30 * 60,
            usageReadbackAttempts: 3,
            usageReadbackDelay: .milliseconds(1)
        )
        let repository = UsageRepository(database: database)
        let state = AppState(
            ingestionCoordinator: UsageIngestionCoordinator(
                sources: [],
                repository: repository,
                maximumWatchFiles: 64
            ),
            sub2APIPoolMonitor: poolMonitor,
            refreshInterval: .seconds(30),
            sub2APIRefreshInterval: .seconds(30),
            fileEventDebounceMilliseconds: 100,
            costEstimator: CostEstimator(catalog: .officialAPI)
        )

        state.startMonitoring()
        defer { state.stopMonitoring() }
        try await Task.sleep(for: .milliseconds(10))

        let didRefresh = await state.refresh(forceRemote: true)
        let usageRefreshCount = await client.usageRefreshCount

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(usageRefreshCount, 2)
        XCTAssertEqual(state.sub2APIStatus, .connected)
        XCTAssertNotNil(state.sub2APIPoolSnapshot)
    }

    func testCrossingNextRecoveryAutomaticallyForcesFreshUsageProbe() async throws {
        let client = RecoveryTimingSub2APIClient(
            recoveryAt: Date().addingTimeInterval(0.15)
        )
        let state = try makeRecoveryState(client: client)

        state.startMonitoring()
        defer { state.stopMonitoring() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await client.usageRefreshCount < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let usageRefreshCountAfterRecovery = await client.usageRefreshCount
        XCTAssertEqual(usageRefreshCountAfterRecovery, 2)
        XCTAssertEqual(state.sub2APIPoolSnapshot?.effectiveCapacity.availableAccounts, 1)
        try await Task.sleep(for: .milliseconds(80))
        let finalUsageRefreshCount = await client.usageRefreshCount
        XCTAssertEqual(finalUsageRefreshCount, 2)
    }

    func testRecoveryRefreshRetriesAfterTransientFailure() async throws {
        let client = RecoveryTimingSub2APIClient(
            recoveryAt: Date().addingTimeInterval(0.15),
            failedRefreshCounts: [2]
        )
        let state = try makeRecoveryState(client: client)

        state.startMonitoring()
        defer { state.stopMonitoring() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            let usageRefreshCount = await client.usageRefreshCount
            if usageRefreshCount >= 3,
               state.sub2APIStatus == .connected,
               state.sub2APIPoolSnapshot?.effectiveCapacity.availableAccounts == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let usageRefreshCount = await client.usageRefreshCount
        XCTAssertEqual(usageRefreshCount, 3)
        XCTAssertEqual(state.sub2APIPoolSnapshot?.effectiveCapacity.availableAccounts, 1)
        XCTAssertEqual(state.sub2APIStatus, .connected)
    }

    private func makeRecoveryState(
        client: any Sub2APIClientServing
    ) throws -> AppState {
        let database = try VibeTokenDatabase.inMemory()
        let connection = Sub2APIConnection(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            email: "admin@example.com"
        )
        let poolMonitor = Sub2APIPoolMonitor(
            client: client,
            sessionStore: CountingSessionStore(
                session: Sub2APISession(accessToken: "test", refreshToken: nil, expiresAt: nil)
            ),
            connectionStore: CountingConnectionStore(connection: connection),
            capacityConfigurationStore: MemoryCapacityConfigurationStore(),
            pageSize: 100,
            maximumPages: 100,
            staleAfter: 15 * 60,
            minimumRefreshInterval: 0,
            usageRefreshInterval: 30 * 60,
            usageReadbackAttempts: 3,
            usageReadbackDelay: .milliseconds(1)
        )
        let repository = UsageRepository(database: database)
        return AppState(
            ingestionCoordinator: UsageIngestionCoordinator(
                sources: [],
                repository: repository,
                maximumWatchFiles: 64
            ),
            sub2APIPoolMonitor: poolMonitor,
            refreshInterval: .seconds(30),
            sub2APIRefreshInterval: .milliseconds(20),
            fileEventDebounceMilliseconds: 100,
            costEstimator: CostEstimator(catalog: .officialAPI)
        )
    }
}

private final class MemoryCapacityConfigurationStore: Sub2APICapacityConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: Sub2APIAccountCapacityConfiguration?

    func load() throws -> Sub2APIAccountCapacityConfiguration? {
        lock.withLock { configuration }
    }

    func save(_ configuration: Sub2APIAccountCapacityConfiguration) throws {
        lock.withLock { self.configuration = configuration }
    }
}

private actor UnusedSub2APIClient: Sub2APIClientServing {
    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult {
        throw Sub2APIError.serverUnavailable
    }

    func completeTwoFactor(baseURL: URL, tempToken: String, code: String) async throws -> Sub2APISession {
        throw Sub2APIError.serverUnavailable
    }

    func fetchAccounts(baseURL: URL, pageSize: Int, maximumPages: Int) async throws -> [Sub2APIAccountPayload] {
        []
    }

    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws {}
}

private actor CountingSub2APIClient: Sub2APIClientServing {
    private(set) var fetchCount = 0

    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult {
        throw Sub2APIError.serverUnavailable
    }

    func completeTwoFactor(baseURL: URL, tempToken: String, code: String) async throws -> Sub2APISession {
        throw Sub2APIError.serverUnavailable
    }

    func fetchAccounts(baseURL: URL, pageSize: Int, maximumPages: Int) async throws -> [Sub2APIAccountPayload] {
        fetchCount += 1
        return []
    }

    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws {}
}

private actor DelayedUsageSub2APIClient: Sub2APIClientServing {
    private(set) var usageRefreshCount = 0

    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult {
        throw Sub2APIError.serverUnavailable
    }

    func completeTwoFactor(baseURL: URL, tempToken: String, code: String) async throws -> Sub2APISession {
        throw Sub2APIError.serverUnavailable
    }

    func fetchAccounts(
        baseURL: URL,
        pageSize: Int,
        maximumPages: Int
    ) async throws -> [Sub2APIAccountPayload] {
        let updatedAt = usageRefreshCount == 0
            ? Date().addingTimeInterval(-60 * 60)
            : Date().addingTimeInterval(TimeInterval(usageRefreshCount))
        let timestamp = ISO8601DateFormatter().string(from: updatedAt)
        let body = #"{"id":1,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"plus"},"extra":{"codex_5h_used_percent":25,"codex_7d_used_percent":50,"codex_usage_updated_at":"\#(timestamp)"}}"#
        return [try JSONDecoder().decode(Sub2APIAccountPayload.self, from: Data(body.utf8))]
    }

    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws {
        usageRefreshCount += 1
        try await Task.sleep(for: .milliseconds(40))
    }
}

private actor RecoveryTimingSub2APIClient: Sub2APIClientServing {
    private let recoveryAt: Date
    private let failedRefreshCounts: Set<Int>
    private(set) var usageRefreshCount = 0

    init(recoveryAt: Date, failedRefreshCounts: Set<Int> = []) {
        self.recoveryAt = recoveryAt
        self.failedRefreshCounts = failedRefreshCounts
    }

    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult {
        throw Sub2APIError.serverUnavailable
    }

    func completeTwoFactor(baseURL: URL, tempToken: String, code: String) async throws -> Sub2APISession {
        throw Sub2APIError.serverUnavailable
    }

    func fetchAccounts(
        baseURL: URL,
        pageSize: Int,
        maximumPages: Int
    ) async throws -> [Sub2APIAccountPayload] {
        let usageUpdatedAt = Date().addingTimeInterval(TimeInterval(usageRefreshCount))
        let body = #"{"id":1,"status":"active","schedulable":true,"parent_account_id":null,"credentials":{"plan_type":"plus"},"extra":{"codex_5h_used_percent":\#(usageRefreshCount >= 2 ? 0 : 100),"codex_5h_reset_at":"\#(timestamp(recoveryAt))","codex_7d_used_percent":20,"codex_usage_updated_at":"\#(timestamp(usageUpdatedAt))"}}"#
        return [try JSONDecoder().decode(Sub2APIAccountPayload.self, from: Data(body.utf8))]
    }

    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws {
        usageRefreshCount += 1
        if failedRefreshCounts.contains(usageRefreshCount) {
            throw Sub2APIError.serverUnavailable
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private final class CountingSessionStore: Sub2APISessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let session: Sub2APISession?
    private var storedLoadCount = 0

    init(session: Sub2APISession?) {
        self.session = session
    }

    var loadCount: Int {
        lock.withLock { storedLoadCount }
    }

    func load() throws -> Sub2APISession? {
        lock.withLock {
            storedLoadCount += 1
            return session
        }
    }

    func save(_ session: Sub2APISession) throws {}
    func delete() throws {}
}

private final class CountingConnectionStore: Sub2APIConnectionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: Sub2APIConnection?
    private var storedLoadCount = 0

    init(connection: Sub2APIConnection?) {
        self.connection = connection
    }

    var loadCount: Int {
        lock.withLock { storedLoadCount }
    }

    func load() throws -> Sub2APIConnection? {
        lock.withLock {
            storedLoadCount += 1
            return connection
        }
    }

    func save(_ connection: Sub2APIConnection) throws {}
    func delete() throws {}
}

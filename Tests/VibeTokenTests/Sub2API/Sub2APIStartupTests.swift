import Foundation
import XCTest
@testable import VibeToken

@MainActor
final class Sub2APIStartupTests: XCTestCase {
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
            minimumRefreshInterval: 30
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

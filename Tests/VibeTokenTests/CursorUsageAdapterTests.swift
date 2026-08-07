import Foundation
import GRDB
import XCTest
@testable import VibeToken

final class CursorUsageAdapterTests: XCTestCase {
    func testParsesQuotedCSVThrottlesRequestsAndAcceptsLowerCloudTotals() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stateDatabaseURL = temporaryDirectory.appendingPathComponent("state.vscdb")
        try await createStateDatabase(at: stateDatabaseURL, token: "test-token")
        let day = Self.utcDay(Date())
        let firstCSV = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        \(day),"claude,sonnet",20,10,5,7
        \(day),"claude,sonnet",3,2,1,4
        """
        let lowerCSV = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        \(day),"claude,sonnet",8,4,2,6
        """
        let transport = CursorTransportStub(results: [
            CursorHTTPResult(data: Data(firstCSV.utf8), statusCode: 200),
            CursorHTTPResult(data: Data(lowerCSV.utf8), statusCode: 200)
        ])
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = CursorUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            stateDatabaseURL: stateDatabaseURL,
            transport: transport,
            minimumFetchInterval: 300
        )
        let now = Date()

        try await adapter.ingestRecentSessions(now: now)
        try await adapter.ingestRecentSessions(now: now.addingTimeInterval(60))
        var aggregate = try repository.aggregate(
            source: "cursor",
            from: now.addingTimeInterval(-172_800),
            through: now.addingTimeInterval(172_800)
        )
        XCTAssertEqual(aggregate.snapshot?.inputTokens, 12)
        XCTAssertEqual(aggregate.snapshot?.cacheWriteTokens, 23)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 6)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 11)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 52)
        let requestCountAfterThrottle = await transport.requestCount()
        XCTAssertEqual(requestCountAfterThrottle, 1)

        try await adapter.ingestRecentSessions(now: now.addingTimeInterval(301))
        aggregate = try repository.aggregate(
            source: "cursor",
            from: now.addingTimeInterval(-172_800),
            through: now.addingTimeInterval(172_800)
        )
        XCTAssertEqual(aggregate.snapshot?.inputTokens, 4)
        XCTAssertEqual(aggregate.snapshot?.cacheWriteTokens, 8)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 2)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 6)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 20)
        let requestCountAfterRefresh = await transport.requestCount()
        XCTAssertEqual(requestCountAfterRefresh, 2)

        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "cursor.com" })
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/dashboard/export-usage-events-csv" })
    }

    func testThrowsActionableErrorAfterAllAuthorizationAttemptsFail() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stateDatabaseURL = temporaryDirectory.appendingPathComponent("state.vscdb")
        try await createStateDatabase(at: stateDatabaseURL, token: "test-token")
        let transport = CursorTransportStub(results: [
            CursorHTTPResult(data: Data(), statusCode: 401),
            CursorHTTPResult(data: Data(), statusCode: 403)
        ])
        let adapter = CursorUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: UsageRepository(database: try VibeTokenDatabase.inMemory()),
            stateDatabaseURL: stateDatabaseURL,
            transport: transport,
            minimumFetchInterval: 0
        )

        do {
            try await adapter.ingestRecentSessions(now: Date())
            XCTFail("Expected authorization rejection")
        } catch CursorUsageError.authorizationRejected {
            let requestCount = await transport.requestCount()
            XCTAssertEqual(requestCount, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func createStateDatabase(at url: URL, token: String) async throws {
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { database in
            try database.create(table: "ItemTable") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
            try database.execute(
                sql: "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
                arguments: ["cursorAuth/accessToken", token]
            )
        }
    }

    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private actor CursorTransportStub: CursorUsageTransport {
    private let results: [CursorHTTPResult]
    private var requests: [URLRequest] = []

    init(results: [CursorHTTPResult]) {
        self.results = results
    }

    func send(_ request: URLRequest) async throws -> CursorHTTPResult {
        let index = requests.count
        requests.append(request)
        return results[min(index, results.count - 1)]
    }

    func requestCount() -> Int { requests.count }

    func capturedRequests() -> [URLRequest] { requests }
}

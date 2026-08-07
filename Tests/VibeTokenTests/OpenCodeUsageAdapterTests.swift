import Foundation
import GRDB
import XCTest
@testable import VibeToken

final class OpenCodeUsageAdapterTests: XCTestCase {
    func testReadsSQLiteInPagesAndPicksUpNewRowsWithoutChangingSourceData() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = temporaryDirectory.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceQueue = try DatabaseQueue(path: dataRoot.appendingPathComponent("opencode.db").path)
        try await sourceQueue.write { database in
            try database.create(table: "message") { table in
                table.column("id", .text).primaryKey()
                table.column("session_id", .text).notNull()
                table.column("data", .text).notNull()
            }
            for index in 1...3 {
                try database.execute(
                    sql: "INSERT INTO message (id, session_id, data) VALUES (?, ?, ?)",
                    arguments: [
                        "message-\(index)",
                        "session-\(index)",
                        Self.openCodeMessage(id: index, input: index * 10)
                    ]
                )
            }
        }

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = OpenCodeUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            dataRoot: dataRoot,
            databasePageSize: 2
        )
        try await adapter.ingestRecentSessions(now: Date())

        var aggregate = try repository.aggregate(
            source: "opencode",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(aggregate.snapshot?.inputTokens, 60)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 15)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 21)
        XCTAssertEqual(aggregate.snapshot?.reasoningTokens, 6)
        XCTAssertEqual(aggregate.sessionCount, 3)

        try await sourceQueue.write { database in
            try database.execute(
                sql: "INSERT INTO message (id, session_id, data) VALUES (?, ?, ?)",
                arguments: ["message-4", "session-4", Self.openCodeMessage(id: 4, input: 40)]
            )
        }
        try await adapter.ingestRecentSessions(now: Date())
        aggregate = try repository.aggregate(
            source: "opencode",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 156)
        XCTAssertEqual(aggregate.sessionCount, 4)

        let sourceCount = try await sourceQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM message")
        }
        XCTAssertEqual(sourceCount, 4)
    }

    func testFallsBackToLegacyJSONMessages() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = temporaryDirectory.appendingPathComponent("opencode", isDirectory: true)
        let messages = dataRoot.appendingPathComponent("storage/message/ses_legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Self.openCodeMessage(id: 1, input: 10).write(
            to: messages.appendingPathComponent("msg_1.json"),
            atomically: true,
            encoding: .utf8
        )

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = OpenCodeUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            dataRoot: dataRoot
        )
        try await adapter.ingestRecentSessions(now: Date())
        let aggregate = try repository.aggregate(
            source: "opencode",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 24)
        XCTAssertEqual(aggregate.sessionCount, 1)
    }

    private static func openCodeMessage(id: Int, input: Int) -> String {
        let created = Int64(Date().timeIntervalSince1970 * 1_000)
        return """
        {"id":"message-\(id)","role":"assistant","time":{"created":\(created)},"modelID":"provider/model-\(id)","tokens":{"input":\(input),"output":7,"reasoning":2,"cache":{"read":5}},"path":{"root":"/Users/test/OpenProject"}}
        """
    }
}

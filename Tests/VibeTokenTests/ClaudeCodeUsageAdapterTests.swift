import Foundation
import XCTest
@testable import VibeToken

final class ClaudeCodeUsageAdapterTests: XCTestCase {
    func testChoosesMostCompleteSessionCopyAndSeparatesClaudeCacheUsage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstRoot = temporaryDirectory.appendingPathComponent("first/.claude", isDirectory: true)
        let secondRoot = temporaryDirectory.appendingPathComponent("second/.claude", isDirectory: true)
        let firstFile = firstRoot.appendingPathComponent("projects/project/session.jsonl")
        let secondFile = secondRoot.appendingPathComponent("projects/project/session.jsonl")
        try FileManager.default.createDirectory(
            at: firstFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        try claudeLine(
            timestamp: timestamp,
            uuid: "same-event",
            input: 1,
            cached: 0,
            cacheCreation: 0,
            output: 1
        ).write(to: firstFile, atomically: true, encoding: .utf8)
        try claudeLine(
            timestamp: timestamp,
            uuid: "same-event",
            input: 10,
            cached: 30,
            cacheCreation: 20,
            output: 40,
            cacheFiveMinutes: 15,
            cacheOneHour: 10
        ).write(to: secondFile, atomically: true, encoding: .utf8)

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = ClaudeCodeUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            rootsOverride: [firstRoot, secondRoot]
        )

        try await adapter.ingestRecentSessions(now: Date())
        try await adapter.ingestRecentSessions(now: Date())
        let aggregate = try repository.aggregate(
            source: "claude-code",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )

        XCTAssertEqual(aggregate.snapshot?.inputTokens, 10)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 30)
        XCTAssertEqual(aggregate.snapshot?.cacheWriteTokens, 25)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 40)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 105)
        XCTAssertEqual(aggregate.sessionCount, 1)
        XCTAssertEqual(aggregate.sourceBreakdowns.first?.displayName, "Claude Code")
    }

    func testDeduplicatesClaudeUUIDAcrossDifferentSessionFiles() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temporaryDirectory.appendingPathComponent(".claude", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("projects/project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = claudeLine(
            timestamp: timestamp,
            uuid: "copied-uuid",
            input: 100,
            cached: 0,
            cacheCreation: 0,
            output: 50
        )
        try line.write(
            to: projectDirectory.appendingPathComponent("session-one.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try line.write(
            to: projectDirectory.appendingPathComponent("session-two.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = ClaudeCodeUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            rootsOverride: [root]
        )
        try await adapter.ingestRecentSessions(now: Date())

        let aggregate = try repository.aggregate(
            source: "claude-code",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 150)
        XCTAssertEqual(aggregate.sessionCount, 1)
    }

    private func claudeLine(
        timestamp: String,
        uuid: String,
        input: Int,
        cached: Int,
        cacheCreation: Int,
        output: Int,
        cacheFiveMinutes: Int = 0,
        cacheOneHour: Int = 0
    ) -> String {
        return """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","cwd":"/Users/test/Project","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cached),"cache_creation_input_tokens":\(cacheCreation),"output_tokens":\(output),"cache_creation":{"ephemeral_5m_input_tokens":\(cacheFiveMinutes),"ephemeral_1h_input_tokens":\(cacheOneHour)}}}}
        """
        + "\n"
    }
}

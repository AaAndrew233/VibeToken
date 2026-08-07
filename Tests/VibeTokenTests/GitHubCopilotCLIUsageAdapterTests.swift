import Foundation
import XCTest
@testable import VibeToken

final class GitHubCopilotCLIUsageAdapterTests: XCTestCase {
    func testParsesShutdownMetricsWithExclusiveCacheCategories() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionRoot = temporaryDirectory.appendingPathComponent("session-state", isDirectory: true)
        let eventsURL = sessionRoot.appendingPathComponent("session-1/events.jsonl")
        try FileManager.default.createDirectory(
            at: eventsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let now = Date()
        let records: [[String: Any]] = [
            [
                "type": "session.start",
                "timestamp": ISO8601DateFormatter().string(from: now),
                "data": ["context": ["gitRoot": "/Users/test/CopilotProject"]]
            ],
            [
                "type": "session.shutdown",
                "timestamp": ISO8601DateFormatter().string(from: now),
                "data": [
                    "modelMetrics": [
                        "claude-sonnet-4": [
                            "usage": [
                                "inputTokens": 100,
                                "cacheReadTokens": 20,
                                "cacheWriteTokens": 10,
                                "outputTokens": 30,
                                "reasoningTokens": 5
                            ]
                        ]
                    ]
                ]
            ]
        ]
        try jsonLines(records).write(to: eventsURL, atomically: true, encoding: .utf8)

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = GitHubCopilotCLIUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            sessionStateRoot: sessionRoot
        )

        try await adapter.ingestRecentSessions(now: now)
        try await adapter.ingestRecentSessions(now: now.addingTimeInterval(1))
        let aggregate = try repository.aggregate(
            source: "copilot-cli",
            from: now.addingTimeInterval(-60),
            through: now.addingTimeInterval(60)
        )

        XCTAssertEqual(aggregate.snapshot?.inputTokens, 70)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 20)
        XCTAssertEqual(aggregate.snapshot?.cacheWriteTokens, 10)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 30)
        XCTAssertEqual(aggregate.snapshot?.reasoningTokens, 5)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 135)
        XCTAssertEqual(aggregate.sessionCount, 1)
    }

    private func jsonLines(_ records: [[String: Any]]) throws -> String {
        try records.map { record in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }.joined(separator: "\n") + "\n"
    }
}

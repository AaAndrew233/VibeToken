import Foundation
import XCTest
@testable import VibeToken

final class VSCodeTaskUsageAdapterTests: XCTestCase {
    func testClineChoosesLargestMigratedCopyAndSeparatesCacheUsage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstRoot = temporaryDirectory.appendingPathComponent("first", isDirectory: true)
        let secondRoot = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try writeClineTask(
            root: firstRoot,
            taskIdentifier: "old-copy",
            ulid: "shared-task",
            request: ["tokensIn": 1, "tokensOut": 1]
        )
        try writeClineTask(
            root: secondRoot,
            taskIdentifier: "new-copy",
            ulid: "shared-task",
            request: [
                "tokensIn": 10,
                "tokensOut": 7,
                "cacheWrites": 5,
                "cacheReads": 3,
                "reasoningTokens": 2,
                "model": "claude-sonnet-4"
            ]
        )

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = VSCodeTaskUsageAdapter(
            tool: .cline,
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            rootsOverride: [firstRoot, secondRoot]
        )
        try await adapter.ingestRecentSessions(now: Date())

        let aggregate = try recentAggregate(repository: repository, source: "cline")
        XCTAssertEqual(aggregate.snapshot?.inputTokens, 10)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 3)
        XCTAssertEqual(aggregate.snapshot?.cacheWriteTokens, 5)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 7)
        XCTAssertEqual(aggregate.snapshot?.reasoningTokens, 2)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 27)
        XCTAssertEqual(aggregate.sessionCount, 1)
    }

    func testRooReadsIndexAndFallsBackToPerTaskHistory() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let indexedRoot = temporaryDirectory.appendingPathComponent("indexed", isDirectory: true)
        let fallbackRoot = temporaryDirectory.appendingPathComponent("fallback", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try writeRooTask(
            root: indexedRoot,
            taskIdentifier: "indexed-task",
            request: ["tokensIn": 8, "tokensOut": 4, "cacheWrites": 2, "cacheReads": 1],
            usesIndex: true
        )
        try writeRooTask(
            root: fallbackRoot,
            taskIdentifier: "fallback-task",
            request: ["tokensIn": 6, "tokensOut": 3, "cacheWrites": 1, "cacheReads": 2],
            usesIndex: false
        )

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = VSCodeTaskUsageAdapter(
            tool: .rooCode,
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            rootsOverride: [indexedRoot, fallbackRoot]
        )
        try await adapter.ingestRecentSessions(now: Date())

        let aggregate = try recentAggregate(repository: repository, source: "roo-code")
        XCTAssertEqual(aggregate.snapshot?.inputTokens, 14)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 3)
        XCTAssertEqual(aggregate.snapshot?.cacheWriteTokens, 3)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 7)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 27)
        XCTAssertEqual(aggregate.sessionCount, 2)
    }

    private func writeClineTask(
        root: URL,
        taskIdentifier: String,
        ulid: String,
        request: [String: Any]
    ) throws {
        let history: [[String: Any]] = [[
            "id": taskIdentifier,
            "ulid": ulid,
            "modelId": "fallback-model",
            "cwdOnTaskInitialization": "/Users/test/ClineProject"
        ]]
        try writeJSON(history, to: root.appendingPathComponent("state/taskHistory.json"))
        try writeMessages(request, to: root.appendingPathComponent(
            "tasks/\(taskIdentifier)/ui_messages.json"
        ))
    }

    private func writeRooTask(
        root: URL,
        taskIdentifier: String,
        request: [String: Any],
        usesIndex: Bool
    ) throws {
        let item: [String: Any] = [
            "id": taskIdentifier,
            "apiConfigName": "fallback-model",
            "workspace": "/Users/test/RooProject"
        ]
        let tasksRoot = root.appendingPathComponent("tasks", isDirectory: true)
        if usesIndex {
            try writeJSON(["entries": [item]], to: tasksRoot.appendingPathComponent("_index.json"))
        } else {
            try writeJSON(item, to: tasksRoot.appendingPathComponent(
                "\(taskIdentifier)/history_item.json"
            ))
        }
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let requestText = try XCTUnwrap(String(data: requestData, encoding: .utf8))
        try writeMessages(
            requestText,
            to: tasksRoot.appendingPathComponent("\(taskIdentifier)/ui_messages.json")
        )
    }

    private func writeMessages(_ request: Any, to url: URL) throws {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        try writeJSON([[
            "type": "say",
            "say": "api_req_started",
            "ts": timestamp,
            "text": request
        ]], to: url)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func recentAggregate(
        repository: UsageRepository,
        source: String
    ) throws -> UsageAggregation {
        try repository.aggregate(
            source: source,
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
    }
}

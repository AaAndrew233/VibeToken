import Foundation
import XCTest
@testable import VibeToken

final class KiroUsageAdapterTests: XCTestCase {
    func testEstimatesNativeSessionWithoutCountingThinkingSignature() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRoot = temporaryDirectory.appendingPathComponent("sessions", isDirectory: true)
        let sessionURL = sessionsRoot.appendingPathComponent("session-1.jsonl")
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signature = String(repeating: "s", count: 400)
        let events: [[String: Any]] = [
            event("Prompt", content: [["kind": "text", "data": "12345678"]], timestamp: timestamp),
            event("AssistantMessage", content: [
                [
                    "kind": "thinking",
                    "data": ["text": "12345678", "signature": signature]
                ],
                [
                    "kind": "text",
                    "data": ["text": "abcdefgh", "modelId": "CLAUDE_SONNET_4_20250514_V1_0"]
                ]
            ]),
            event("Prompt", content: [["kind": "text", "data": "1234"]], timestamp: timestamp),
            event("ToolResults", content: [["kind": "text", "data": "abcdefgh"]]),
            event("AssistantMessage", content: [["kind": "text", "data": "1234"]]),
            ["kind": "Compaction", "data": ["summary": "12345678901234567890"]],
            event("Prompt", content: [["kind": "text", "data": "1234"]], timestamp: timestamp),
            event("AssistantMessage", content: [["kind": "text", "data": "1234"]])
        ]
        try jsonLines(events).write(to: sessionURL, atomically: true, encoding: .utf8)
        try writeJSON([
            "cwd": "/Users/test/KiroProject",
            "session_state": [
                "rts_model_state": [
                    "model_info": ["model_id": "CLAUDE_SONNET_4_20250514_V1_0"]
                ]
            ]
        ], to: sessionsRoot.appendingPathComponent("session-1.json"))

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = KiroUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            sessionsRoot: sessionsRoot
        )
        try await adapter.ingestRecentSessions(now: Date())

        let aggregate = try repository.aggregate(
            source: "kiro",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(aggregate.snapshot?.inputTokens, 6)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 11)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 4)
        XCTAssertEqual(aggregate.snapshot?.reasoningTokens, 2)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 23)
        XCTAssertEqual(aggregate.snapshot?.accuracy, .estimated)
        XCTAssertEqual(aggregate.sessionCount, 1)
        XCTAssertEqual(aggregate.modelSnapshots.first?.model, "claude-sonnet-4")
    }

    private func event(
        _ kind: String,
        content: [[String: Any]],
        timestamp: String? = nil
    ) -> [String: Any] {
        var data: [String: Any] = ["content": content]
        if let timestamp {
            data["meta"] = ["timestamp": timestamp]
        }
        return ["kind": kind, "data": data]
    }

    private func jsonLines(_ records: [[String: Any]]) throws -> String {
        try records.map { record in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }.joined(separator: "\n") + "\n"
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

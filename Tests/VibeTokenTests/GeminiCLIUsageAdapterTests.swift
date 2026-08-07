import Foundation
import XCTest
@testable import VibeToken

final class GeminiCLIUsageAdapterTests: XCTestCase {
    func testParsesCurrentJSONLAndNestedSubagentWithExclusiveTokenCategories() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = temporaryDirectory.appendingPathComponent(".gemini/tmp", isDirectory: true)
        let chats = dataRoot.appendingPathComponent("hash/chats", isDirectory: true)
        let nested = chats.appendingPathComponent("parent/subagent", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadata = #"{"directories":["/Users/test/GeminiProject"]}"#
        let message = """
        {"id":"assistant-1","type":"gemini","timestamp":"\(timestamp)","model":"gemini-2.5-pro","tokens":{"input":100,"output":50,"cached":25,"thoughts":10}}
        """
        try (metadata + "\n" + message + "\n").write(
            to: chats.appendingPathComponent("session-main.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try (metadata + "\n" + message.replacingOccurrences(of: "assistant-1", with: "assistant-2") + "\n")
            .write(
                to: nested.appendingPathComponent("session-child.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = GeminiCLIUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            dataRoot: dataRoot
        )
        try await adapter.ingestRecentSessions(now: Date())

        let aggregate = try repository.aggregate(
            source: "gemini-cli",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(aggregate.snapshot?.inputTokens, 150)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 50)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 80)
        XCTAssertEqual(aggregate.snapshot?.reasoningTokens, 20)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 300)
        XCTAssertEqual(aggregate.sessionCount, 2)
    }

    func testParsesLegacyJSONUsageMetadataWithoutDoublingFallbackFields() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = temporaryDirectory.appendingPathComponent(".gemini/tmp", isDirectory: true)
        let chats = dataRoot.appendingPathComponent("hash/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let json = """
        {"directories":["/Users/test/Legacy"],"messages":[{"id":"legacy","role":"assistant","createTime":"\(timestamp)","model":"gemini-2.0-flash","usageMetadata":{"promptTokenCount":80,"input_tokens":80,"candidatesTokenCount":30,"output_tokens":30,"cachedContentTokenCount":20,"thoughtsTokenCount":5}}]}
        """
        try json.write(
            to: chats.appendingPathComponent("session-legacy.json"),
            atomically: true,
            encoding: .utf8
        )

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = GeminiCLIUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: temporaryDirectory),
            repository: repository,
            dataRoot: dataRoot
        )
        try await adapter.ingestRecentSessions(now: Date())
        let aggregate = try repository.aggregate(
            source: "gemini-cli",
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )

        XCTAssertEqual(aggregate.snapshot?.inputTokens, 60)
        XCTAssertEqual(aggregate.snapshot?.cachedInputTokens, 20)
        XCTAssertEqual(aggregate.snapshot?.outputTokens, 25)
        XCTAssertEqual(aggregate.snapshot?.reasoningTokens, 5)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 110)
    }
}

import Foundation
import XCTest
@testable import VibeToken

final class CodexUsageAdapterTests: XCTestCase {
    func testAggregatesMultipleSessionsWithoutDoubleCountingRescan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let dayDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            at: dayDirectory.appendingPathComponent("rollout-one.jsonl"),
            timestamp: now.addingTimeInterval(-60),
            total: 100
        )
        try writeSession(
            at: dayDirectory.appendingPathComponent("rollout-two.jsonl"),
            timestamp: now.addingTimeInterval(-120),
            total: 200
        )

        let database = try VibeTokenDatabase.inMemory()
        let adapter = CodexUsageAdapter(
            configuration: configuration(codexHome: codexHome),
            repository: UsageRepository(database: database)
        )
        try await adapter.ingestRecentSessions(now: now)
        try await adapter.ingestRecentSessions(now: now)
        let aggregate = try await adapter.aggregate(range: .hours24, now: now)

        XCTAssertEqual(aggregate.snapshot?.totalTokens, 300)
        XCTAssertEqual(aggregate.sessionCount, 2)
        XCTAssertEqual(aggregate.modelSnapshots.map(\.model), ["gpt-5.6-sol"])
    }

    private func configuration(codexHome: URL) -> AppConfiguration {
        AppConfiguration(
            codexHome: codexHome,
            applicationSupportDirectory: codexHome,
            refreshInterval: .seconds(5),
            fileEventDebounceMilliseconds: 100,
            maximumTailBytes: 1_024 * 1_024,
            ingestionChunkBytes: 64 * 1_024,
            maximumJSONLineBytes: 1_024 * 1_024,
            historyLookbackDays: 30,
            maximumWatchedSessionFiles: 64
        )
    }

    private func writeSession(at fileURL: URL, timestamp: Date, total: Int64) throws {
        let timestampText = ISO8601DateFormatter().string(from: timestamp)
        let lines = [
            #"{"timestamp":"\#(timestampText)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"\#(timestampText)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)}}}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
    }
}

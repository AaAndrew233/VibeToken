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

    func testLegacySavedCodexHomeIsScannedWithoutReplacingAutomaticDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("custom-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "VibeTokenTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(codexHome.path, forKey: AppConfiguration.codexHomeOverrideKey)

        let configuration = AppConfiguration.live(environment: [:], userDefaults: defaults)
        XCTAssertEqual(
            configuration.codexHome.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true).path
        )
        XCTAssertTrue(configuration.additionalCodexHomes.contains {
            $0.standardizedFileURL.path == codexHome.standardizedFileURL.path
        })
    }

    func testAutomaticallyScansAdditionalProfileAndArchivedSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingHome = root.appendingPathComponent("missing", isDirectory: true)
        let availableHome = root.appendingPathComponent(".codex-work", isDirectory: true)
        let archiveDirectory = availableHome.appendingPathComponent(
            "archived_sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try writeSession(
            at: archiveDirectory.appendingPathComponent("archived-rollout.jsonl"),
            timestamp: now,
            total: 88
        )

        let adapter = CodexUsageAdapter(
            configuration: configuration(
                codexHome: missingHome,
                additionalCodexHomes: [availableHome]
            ),
            repository: UsageRepository(database: try VibeTokenDatabase.inMemory())
        )
        let discovered = await adapter.discover()
        XCTAssertTrue(discovered)
        try await adapter.ingestRecentSessions(now: now)
        let aggregate = try await adapter.aggregate(range: .hours24, now: now)
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 88)
    }

    private func configuration(
        codexHome: URL,
        additionalCodexHomes: [URL] = []
    ) -> AppConfiguration {
        AppConfiguration(
            codexHome: codexHome,
            applicationSupportDirectory: codexHome,
            refreshInterval: .seconds(5),
            fileEventDebounceMilliseconds: 100,
            maximumTailBytes: 1_024 * 1_024,
            ingestionChunkBytes: 64 * 1_024,
            maximumJSONLineBytes: 1_024 * 1_024,
            historyLookbackDays: 30,
            maximumWatchedSessionFiles: 64,
            maximumUsageSourceFiles: 1_000,
            maximumStructuredUsageFileBytes: 1_024 * 1_024,
            additionalCodexHomes: additionalCodexHomes
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

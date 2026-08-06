import Foundation
import XCTest
@testable import VibeToken

final class CodexTokenEventParserTests: XCTestCase {
    func testParsesLatestCumulativeUsageAndNormalizesSubcategories() throws {
        let fileURL = try makeFixture(
            lines: [
                #"{"timestamp":"2026-08-05T09:00:00.000Z","type":"session_meta","payload":{"model":"gpt-5"}}"#,
                #"{"timestamp":"2026-08-05T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":100,"output_tokens":500,"reasoning_output_tokens":200,"total_tokens":1500}}}}"#
            ]
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let snapshot = try XCTUnwrap(
            CodexTokenEventParser().parseLatestUsage(in: fileURL, maximumTailBytes: 1_024 * 1_024)
        )

        XCTAssertEqual(snapshot.model, "gpt-5")
        XCTAssertEqual(snapshot.inputTokens, 300)
        XCTAssertEqual(snapshot.cachedInputTokens, 600)
        XCTAssertEqual(snapshot.cacheWriteTokens, 100)
        XCTAssertEqual(snapshot.outputTokens, 300)
        XCTAssertEqual(snapshot.reasoningTokens, 200)
        XCTAssertEqual(snapshot.totalTokens, 1_500)
        XCTAssertEqual(snapshot.accuracy, .exact)
    }

    func testIgnoresIncompleteTrailingLine() throws {
        let fileURL = try makeFixture(
            lines: [
                #"{"timestamp":"2026-08-05T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":25}}}}"#,
                #"{"type":"event_msg""#
            ]
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let snapshot = try XCTUnwrap(
            CodexTokenEventParser().parseLatestUsage(in: fileURL, maximumTailBytes: 1_024 * 1_024)
        )
        XCTAssertEqual(snapshot.totalTokens, 25)
    }

    func testParsesIncrementalLastUsageAndCarriesModelState() throws {
        let fileURL = try makeFixture(
            lines: [
                #"{"timestamp":"2026-08-05T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                #"{"timestamp":"2026-08-05T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":10,"output_tokens":50,"reasoning_output_tokens":20,"total_tokens":150},"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":10,"output_tokens":50,"reasoning_output_tokens":20,"total_tokens":150}}}}"#,
                #"{"timestamp":"2026-08-05T09:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":220,"cached_input_tokens":120,"cache_write_input_tokens":20,"output_tokens":80,"reasoning_output_tokens":30,"total_tokens":300},"last_token_usage":{"input_tokens":120,"cached_input_tokens":60,"cache_write_input_tokens":10,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":150}}}}"#
            ]
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let batch = try CodexTokenEventParser().parseIncrementalUsage(
            in: fileURL,
            sessionIdentifier: "session",
            initialState: .initial,
            chunkBytes: 64 * 1_024,
            maximumLineBytes: 1_024 * 1_024
        )

        XCTAssertEqual(batch.events.count, 2)
        XCTAssertEqual(batch.events[0].model, "gpt-5.6-sol")
        XCTAssertEqual(batch.events[0].counters.inputTokens, 30)
        XCTAssertEqual(batch.events[0].counters.cachedInputTokens, 60)
        XCTAssertEqual(batch.events[0].counters.cacheWriteTokens, 10)
        XCTAssertEqual(batch.events[1].counters.totalTokens, 150)
        XCTAssertEqual(batch.nextState.currentModel, "gpt-5.6-sol")
        XCTAssertEqual(batch.latestSnapshot?.totalTokens, 300)
    }

    func testSuppressesDuplicateEmissionWhenCumulativeTotalDoesNotChange() throws {
        let repeatedUsage = #"{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":120}"#
        let fileURL = try makeFixture(
            lines: [
                #"{"timestamp":"2026-08-05T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(repeatedUsage),"last_token_usage":\#(repeatedUsage)}}}"#,
                #"{"timestamp":"2026-08-05T09:01:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(repeatedUsage),"last_token_usage":\#(repeatedUsage)}}}"#
            ]
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let batch = try CodexTokenEventParser().parseIncrementalUsage(
            in: fileURL,
            sessionIdentifier: "session",
            initialState: .initial,
            chunkBytes: 64 * 1_024,
            maximumLineBytes: 1_024 * 1_024
        )

        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.events.first?.counters.totalTokens, 120)
        XCTAssertEqual(batch.rawTokenRecords.count, 2)
        XCTAssertEqual(batch.nextState.rawTokenCount, 2)
        XCTAssertEqual(batch.nextState.lastRawCumulativeTotal, 120)
    }

    func testDoesNotSuppressPositiveLastUsageWhenRawCumulativeTotalIsZero() throws {
        let totalUsage = #"{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":0}"#
        let lastUsage = #"{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":120}"#
        let fileURL = try makeFixture(
            lines: [
                #"{"timestamp":"2026-08-05T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(totalUsage),"last_token_usage":\#(lastUsage)}}}"#,
                #"{"timestamp":"2026-08-05T09:01:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(totalUsage),"last_token_usage":\#(lastUsage)}}}"#
            ]
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let batch = try CodexTokenEventParser().parseIncrementalUsage(
            in: fileURL,
            sessionIdentifier: "session",
            initialState: .initial,
            chunkBytes: 64 * 1_024,
            maximumLineBytes: 1_024 * 1_024
        )

        XCTAssertEqual(batch.events.count, 2)
        XCTAssertEqual(batch.events.map(\.counters.totalTokens), [120, 120])
        XCTAssertEqual(batch.nextState.lastRawCumulativeTotal, 0)
    }

    func testExtractsForkAndSubagentSessionMetadata() throws {
        let fileURL = try makeFixture(
            lines: [
                #"{"timestamp":"2026-08-05T09:00:00Z","type":"session_meta","payload":{"id":"child","forked_from_id":"fork-source","timestamp":"2026-08-05T09:00:00Z","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#
            ]
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let batch = try CodexTokenEventParser().parseIncrementalUsage(
            in: fileURL,
            sessionIdentifier: "session",
            initialState: .initial,
            chunkBytes: 64 * 1_024,
            maximumLineBytes: 1_024 * 1_024
        )

        let metadata = try XCTUnwrap(batch.sessionMetadata)
        XCTAssertNotNil(metadata.sessionHash)
        XCTAssertNotNil(metadata.parentSessionHash)
        XCTAssertNotNil(metadata.forkedFromSessionHash)
        XCTAssertTrue(metadata.isSubagent)
        XCTAssertNotNil(metadata.createdAt)
    }

    func testIncrementalParserLeavesIncompleteLineForNextRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("rollout-test.jsonl")
        let modelLine = #"{"timestamp":"2026-08-05T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
        let usageLine = #"{"timestamp":"2026-08-05T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":25},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":25}}}}"#
        try (modelLine + "\n" + usageLine.prefix(80)).write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }

        let parser = CodexTokenEventParser()
        let first = try parser.parseIncrementalUsage(
            in: fileURL,
            sessionIdentifier: "session",
            initialState: .initial,
            chunkBytes: 64 * 1_024,
            maximumLineBytes: 1_024 * 1_024
        )
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(first.nextState.byteOffset, UInt64(modelLine.utf8.count + 1))

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usageLine.dropFirst(80) + "\n").utf8))
        try handle.close()

        let second = try parser.parseIncrementalUsage(
            in: fileURL,
            sessionIdentifier: "session",
            initialState: first.nextState,
            chunkBytes: 64 * 1_024,
            maximumLineBytes: 1_024 * 1_024
        )
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events[0].model, "gpt-5.6-sol")
        XCTAssertEqual(second.events[0].counters.totalTokens, 25)
    }

    private func makeFixture(lines: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("rollout-test.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        return fileURL
    }
}

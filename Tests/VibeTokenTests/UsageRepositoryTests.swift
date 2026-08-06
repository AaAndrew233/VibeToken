import Foundation
import GRDB
import XCTest
@testable import VibeToken

final class UsageRepositoryTests: XCTestCase {
    func testPersistsIdempotentlyAndAggregatesAllSessionsInRange() throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let batch = CodexParseBatch(
            events: [
                event(key: "a", session: "one", model: "gpt-5.6-sol", date: now.addingTimeInterval(-60), total: 100),
                event(key: "b", session: "two", model: "gpt-5.6-sol", date: now.addingTimeInterval(-120), total: 200),
                event(key: "old", session: "old", model: "gpt-5.6-sol", date: now.addingTimeInterval(-90_000), total: 400)
            ],
            nextState: CodexParserState(
                byteOffset: 500,
                currentModel: "gpt-5.6-sol",
                lastCumulative: counters(total: 300)
            ),
            latestSnapshot: nil
        )

        try repository.persist(
            batch: batch,
            fileIdentity: "file",
            canonicalPathHash: "path",
            sourceDisplayName: "Codex"
        )
        try repository.persist(
            batch: batch,
            fileIdentity: "file",
            canonicalPathHash: "path",
            sourceDisplayName: "Codex"
        )

        let result = try repository.aggregate(
            source: "codex",
            from: now.addingTimeInterval(-86_400),
            through: now
        )
        XCTAssertEqual(result.snapshot?.totalTokens, 300)
        XCTAssertEqual(result.sessionCount, 2)
        XCTAssertEqual(result.modelSnapshots.count, 1)
        XCTAssertEqual(try repository.checkpoint(fileIdentity: "file")?.byteOffset, 500)

        let eventCount = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events")
        }
        XCTAssertEqual(eventCount, 3)
    }

    func testAggregatesModelAndToolBreakdownsAcrossSources() throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let now = Date(timeIntervalSince1970: 3_000_000)

        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO usage_sources (id, kind, display_name, status, accuracy)
                    VALUES ('codex', 'local_jsonl', 'Codex', 'online', 'exact'),
                           ('claude-code', 'local_jsonl', 'Claude Code', 'online', 'exact')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO conversations (
                        id, source_id, external_session_hash, model_id, started_at, last_event_at
                    ) VALUES
                        ('codex:one', 'codex', 'one', 'shared-model', ?, ?),
                        ('claude:two', 'claude-code', 'two', 'shared-model', ?, ?),
                        ('claude:three', 'claude-code', 'three', 'claude-model', ?, ?)
                    """,
                arguments: [now, now, now, now, now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO usage_events (
                        idempotency_key, conversation_id, occurred_at, model_id,
                        input_tokens, cached_input_tokens, cache_write_tokens,
                        output_tokens, reasoning_tokens, total_tokens, accuracy
                    ) VALUES
                        ('codex-event', 'codex:one', ?, 'shared-model', 100, 0, 0, 0, 0, 100, 'exact'),
                        ('claude-shared', 'claude:two', ?, 'shared-model', 200, 0, 0, 0, 0, 200, 'exact'),
                        ('claude-model', 'claude:three', ?, 'claude-model', 300, 0, 0, 0, 0, 300, 'exact')
                    """,
                arguments: [now, now, now]
            )
        }

        let result = try repository.aggregate(
            source: nil,
            from: now.addingTimeInterval(-60),
            through: now.addingTimeInterval(60)
        )

        XCTAssertEqual(result.snapshot?.totalTokens, 600)
        XCTAssertEqual(result.sessionCount, 3)
        XCTAssertEqual(result.modelSnapshots.map(\.model), ["claude-model", "shared-model"])
        XCTAssertEqual(result.modelSnapshots.map(\.totalTokens), [300, 300])
        XCTAssertEqual(result.sourceBreakdowns.map(\.displayName), ["Claude Code", "Codex"])
        XCTAssertEqual(
            result.sourceBreakdowns.map { breakdown in
                breakdown.modelSnapshots.reduce(0) { $0 + $1.totalTokens }
            },
            [500, 100]
        )
    }

    func testRemovesForkReplayWhenParentIsPersistedFirst() throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let baseDate = Date(timeIntervalSince1970: 4_000_000)

        try persist(
            batch: replayBatch(
                session: "parent",
                canonicalHash: "parent-hash",
                createdAt: baseDate,
                fingerprints: ["a", "b", "c"],
                totals: [10, 20, 30]
            ),
            session: "parent",
            repository: repository
        )
        try persist(
            batch: replayBatch(
                session: "child",
                canonicalHash: "child-hash",
                forkedFromHash: "parent-hash",
                createdAt: baseDate.addingTimeInterval(100),
                fingerprints: ["a", "b", "c", "d"],
                totals: [10, 20, 30, 40]
            ),
            session: "child",
            repository: repository
        )

        let result = try repository.aggregate(
            source: "codex",
            from: baseDate.addingTimeInterval(-1),
            through: baseDate.addingTimeInterval(200)
        )
        XCTAssertEqual(result.snapshot?.totalTokens, 100)
        XCTAssertEqual(result.sessionCount, 2)
        XCTAssertEqual(try replayBoundary(database: database, conversationID: "codex:child"), 3)
    }

    func testRemovesForkReplayWhenChildIsPersistedBeforeParent() throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let baseDate = Date(timeIntervalSince1970: 5_000_000)
        let parent = replayBatch(
            session: "parent",
            canonicalHash: "parent-hash",
            createdAt: baseDate,
            fingerprints: ["a", "b", "c"],
            totals: [10, 20, 30]
        )
        let child = replayBatch(
            session: "child",
            canonicalHash: "child-hash",
            forkedFromHash: "parent-hash",
            createdAt: baseDate.addingTimeInterval(100),
            fingerprints: ["a", "b", "c", "d"],
            totals: [10, 20, 30, 40]
        )

        try persist(batch: child, session: "child", repository: repository)
        try persist(batch: parent, session: "parent", repository: repository)

        let result = try repository.aggregate(
            source: "codex",
            from: baseDate.addingTimeInterval(-1),
            through: baseDate.addingTimeInterval(200)
        )
        XCTAssertEqual(result.snapshot?.totalTokens, 100)
        XCTAssertEqual(try replayBoundary(database: database, conversationID: "codex:child"), 3)
    }

    func testRemovesPartialSubagentReplayAndKeepsNewUsage() throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let baseDate = Date(timeIntervalSince1970: 6_000_000)

        try persist(
            batch: replayBatch(
                session: "parent",
                canonicalHash: "parent-hash",
                createdAt: baseDate,
                fingerprints: ["a", "b", "c", "d"],
                totals: [10, 20, 30, 40]
            ),
            session: "parent",
            repository: repository
        )
        try persist(
            batch: replayBatch(
                session: "subagent",
                canonicalHash: "subagent-hash",
                parentHash: "parent-hash",
                isSubagent: true,
                createdAt: baseDate.addingTimeInterval(100),
                fingerprints: ["b", "c", "new"],
                totals: [20, 30, 50]
            ),
            session: "subagent",
            repository: repository
        )

        let result = try repository.aggregate(
            source: "codex",
            from: baseDate.addingTimeInterval(-1),
            through: baseDate.addingTimeInterval(200)
        )
        XCTAssertEqual(result.snapshot?.totalTokens, 150)
        XCTAssertEqual(try replayBoundary(database: database, conversationID: "codex:subagent"), 2)
    }

    func testDoesNotDeduplicateIndependentSessionsWithIdenticalTokenPayloads() throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let baseDate = Date(timeIntervalSince1970: 7_000_000)

        for session in ["one", "two"] {
            try persist(
                batch: replayBatch(
                    session: session,
                    canonicalHash: "\(session)-hash",
                    createdAt: baseDate,
                    fingerprints: ["same-a", "same-b"],
                    totals: [10, 20]
                ),
                session: session,
                repository: repository
            )
        }

        let result = try repository.aggregate(
            source: "codex",
            from: baseDate.addingTimeInterval(-1),
            through: baseDate.addingTimeInterval(10)
        )
        XCTAssertEqual(result.snapshot?.totalTokens, 60)
        XCTAssertEqual(result.sessionCount, 2)
        XCTAssertEqual(try replayBoundary(database: database, conversationID: "codex:two"), 0)
    }

    private func event(
        key: String,
        session: String,
        model: String,
        date: Date,
        total: Int64,
        rawTokenOrdinal: Int64? = nil,
        replayFingerprint: String? = nil
    ) -> CodexUsageEvent {
        CodexUsageEvent(
            idempotencyKey: key,
            sessionIdentifier: session,
            model: model,
            occurredAt: date,
            counters: counters(total: total),
            rawTokenOrdinal: rawTokenOrdinal,
            replayFingerprint: replayFingerprint
        )
    }

    private func replayBatch(
        session: String,
        canonicalHash: String,
        parentHash: String? = nil,
        forkedFromHash: String? = nil,
        isSubagent: Bool = false,
        createdAt: Date,
        fingerprints: [String],
        totals: [Int64]
    ) -> CodexParseBatch {
        precondition(fingerprints.count == totals.count)
        let records = fingerprints.enumerated().map { index, fingerprint in
            CodexRawTokenRecord(
                rawTokenOrdinal: Int64(index + 1),
                replayFingerprint: fingerprint,
                occurredAt: createdAt.addingTimeInterval(TimeInterval(index))
            )
        }
        let events = zip(fingerprints, totals).enumerated().map { index, pair in
            event(
                key: "\(session)-\(index)",
                session: session,
                model: "gpt-5.6-sol",
                date: createdAt.addingTimeInterval(TimeInterval(index)),
                total: pair.1,
                rawTokenOrdinal: Int64(index + 1),
                replayFingerprint: pair.0
            )
        }
        return CodexParseBatch(
            events: events,
            nextState: CodexParserState(
                byteOffset: UInt64(fingerprints.count * 100),
                currentModel: "gpt-5.6-sol",
                lastCumulative: counters(total: totals.reduce(0, +)),
                rawTokenCount: Int64(fingerprints.count)
            ),
            latestSnapshot: nil,
            rawTokenRecords: records,
            sessionMetadata: CodexSessionMetadata(
                sessionHash: canonicalHash,
                parentSessionHash: parentHash,
                forkedFromSessionHash: forkedFromHash,
                createdAt: createdAt,
                isSubagent: isSubagent
            )
        )
    }

    private func persist(
        batch: CodexParseBatch,
        session: String,
        repository: UsageRepository
    ) throws {
        try repository.persist(
            batch: batch,
            fileIdentity: session,
            canonicalPathHash: "path-\(session)",
            sourceDisplayName: "Codex"
        )
    }

    private func replayBoundary(
        database: VibeTokenDatabase,
        conversationID: String
    ) throws -> Int64 {
        try database.writer.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT replay_token_count FROM conversations WHERE id = ?",
                arguments: [conversationID]
            ) ?? 0
        }
    }

    private func counters(total: Int64) -> TokenUsageCounters {
        TokenUsageCounters(
            inputTokens: total,
            cachedInputTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            totalTokens: total
        )
    }
}

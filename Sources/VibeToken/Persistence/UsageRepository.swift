import Foundation
import GRDB

struct UsageRepository: Sendable {
    private let database: VibeTokenDatabase

    init(database: VibeTokenDatabase) {
        self.database = database
    }

    func checkpoint(fileIdentity: String) throws -> CodexParserState? {
        try database.writer.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT byte_offset, current_model, has_cumulative, raw_token_count,
                           last_raw_cumulative_total,
                           last_input_tokens, last_cached_input_tokens,
                           last_cache_write_tokens, last_output_tokens,
                           last_reasoning_tokens, last_total_tokens
                    FROM ingest_checkpoints
                    WHERE source_id = ? AND file_identity = ?
                    """,
                arguments: ["codex", fileIdentity]
            ) else {
                return nil
            }

            let hasCumulative: Bool = row["has_cumulative"]
            let cumulative: TokenUsageCounters? = hasCumulative
                ? TokenUsageCounters(
                    inputTokens: row["last_input_tokens"],
                    cachedInputTokens: row["last_cached_input_tokens"],
                    cacheWriteTokens: row["last_cache_write_tokens"],
                    outputTokens: row["last_output_tokens"],
                    reasoningTokens: row["last_reasoning_tokens"],
                    totalTokens: row["last_total_tokens"]
                )
                : nil

            let offset: Int64 = row["byte_offset"]
            return CodexParserState(
                byteOffset: UInt64(max(0, offset)),
                currentModel: row["current_model"],
                lastCumulative: cumulative,
                lastRawCumulativeTotal: row["last_raw_cumulative_total"],
                rawTokenCount: row["raw_token_count"]
            )
        }
    }

    func checkpoint(sourceIdentifier: String, fileIdentity: String) throws -> LocalFileCheckpoint? {
        try database.writer.read { database in
            guard let offset = try Int64.fetchOne(
                database,
                sql: """
                    SELECT byte_offset
                    FROM ingest_checkpoints
                    WHERE source_id = ? AND file_identity = ?
                    """,
                arguments: [sourceIdentifier, fileIdentity]
            ) else {
                return nil
            }
            return LocalFileCheckpoint(byteOffset: UInt64(max(0, offset)))
        }
    }

    func persistedCounters(
        sourceIdentifier: String,
        sessionIdentifier: String
    ) throws -> TokenUsageCounters {
        let conversationID = "\(sourceIdentifier):\(sessionIdentifier)"
        return try database.writer.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT COALESCE(SUM(input_tokens), 0) AS input_tokens,
                           COALESCE(SUM(cached_input_tokens), 0) AS cached_input_tokens,
                           COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
                           COALESCE(SUM(output_tokens), 0) AS output_tokens,
                           COALESCE(SUM(reasoning_tokens), 0) AS reasoning_tokens,
                           COALESCE(SUM(total_tokens), 0) AS total_tokens
                    FROM usage_events
                    WHERE conversation_id = ?
                    """,
                arguments: [conversationID]
            ) else {
                return .zero
            }
            return TokenUsageCounters(
                inputTokens: row["input_tokens"],
                cachedInputTokens: row["cached_input_tokens"],
                cacheWriteTokens: row["cache_write_tokens"],
                outputTokens: row["output_tokens"],
                reasoningTokens: row["reasoning_tokens"],
                totalTokens: row["total_tokens"]
            )
        }
    }

    func persist(
        batch: CodexParseBatch,
        fileIdentity: String,
        canonicalPathHash: String,
        sourceDisplayName: String
    ) throws {
        try database.writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO usage_sources (id, kind, display_name, status, accuracy, last_scan_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        status = excluded.status,
                        accuracy = excluded.accuracy,
                        last_scan_at = excluded.last_scan_at,
                        last_error_code = NULL
                    """,
                arguments: ["codex", "local_jsonl", sourceDisplayName, "online", "exact", Date()]
            )

            let insertConversation = try database.makeStatement(sql: """
                INSERT INTO conversations (
                    id, source_id, external_session_hash, model_id, started_at, last_event_at,
                    canonical_session_hash, parent_session_hash, forked_from_session_hash,
                    session_created_at, is_subagent
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    model_id = COALESCE(excluded.model_id, conversations.model_id),
                    canonical_session_hash = COALESCE(
                        excluded.canonical_session_hash, conversations.canonical_session_hash
                    ),
                    parent_session_hash = COALESCE(
                        excluded.parent_session_hash, conversations.parent_session_hash
                    ),
                    forked_from_session_hash = COALESCE(
                        excluded.forked_from_session_hash, conversations.forked_from_session_hash
                    ),
                    session_created_at = COALESCE(
                        excluded.session_created_at, conversations.session_created_at
                    ),
                    is_subagent = MAX(excluded.is_subagent, conversations.is_subagent),
                    started_at = CASE
                        WHEN conversations.started_at IS NULL OR excluded.started_at < conversations.started_at
                        THEN excluded.started_at ELSE conversations.started_at END,
                    last_event_at = CASE
                        WHEN conversations.last_event_at IS NULL OR excluded.last_event_at > conversations.last_event_at
                        THEN excluded.last_event_at ELSE conversations.last_event_at END
                """)
            let insertEvent = try database.makeStatement(sql: """
                INSERT OR IGNORE INTO usage_events (
                    idempotency_key, conversation_id, occurred_at, model_id,
                    input_tokens, cached_input_tokens, cache_write_tokens,
                    output_tokens, reasoning_tokens, total_tokens,
                    accuracy, raw_schema_version, raw_token_ordinal, replay_fingerprint
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)

            let primaryConversationID = "codex:\(fileIdentity)"
            let metadata = batch.sessionMetadata
            let primaryEvents = batch.events.filter { $0.sessionIdentifier == fileIdentity }
            var changedConversationIDs = Set<String>()

            if metadata != nil || !batch.rawTokenRecords.isEmpty {
                try insertConversation.execute(arguments: [
                    primaryConversationID,
                    "codex",
                    fileIdentity,
                    primaryEvents.first?.model,
                    primaryEvents.first?.occurredAt ?? metadata?.createdAt,
                    primaryEvents.last?.occurredAt ?? metadata?.createdAt,
                    metadata?.sessionHash,
                    metadata?.parentSessionHash,
                    metadata?.forkedFromSessionHash,
                    metadata?.createdAt,
                    metadata?.isSubagent ?? false
                ])
                changedConversationIDs.insert(primaryConversationID)
            }

            let insertRawToken = try database.makeStatement(sql: """
                INSERT OR IGNORE INTO codex_raw_token_records (
                    conversation_id, raw_token_ordinal, replay_fingerprint, occurred_at
                ) VALUES (?, ?, ?, ?)
                """)
            for record in batch.rawTokenRecords {
                try insertRawToken.execute(arguments: [
                    primaryConversationID,
                    record.rawTokenOrdinal,
                    record.replayFingerprint,
                    record.occurredAt
                ])
            }

            for event in batch.events {
                let conversationID = "codex:\(event.sessionIdentifier)"
                let isPrimaryConversation = event.sessionIdentifier == fileIdentity
                try insertConversation.execute(arguments: [
                    conversationID,
                    "codex",
                    event.sessionIdentifier,
                    event.model,
                    event.occurredAt,
                    event.occurredAt,
                    isPrimaryConversation ? metadata?.sessionHash : nil,
                    isPrimaryConversation ? metadata?.parentSessionHash : nil,
                    isPrimaryConversation ? metadata?.forkedFromSessionHash : nil,
                    isPrimaryConversation ? metadata?.createdAt : nil,
                    isPrimaryConversation ? metadata?.isSubagent ?? false : false
                ])
                changedConversationIDs.insert(conversationID)
                try insertEvent.execute(arguments: [
                    event.idempotencyKey,
                    conversationID,
                    event.occurredAt,
                    event.model,
                    event.counters.inputTokens,
                    event.counters.cachedInputTokens,
                    event.counters.cacheWriteTokens,
                    event.counters.outputTokens,
                    event.counters.reasoningTokens,
                    event.counters.totalTokens,
                    "exact",
                    "codex-token-count-v2",
                    event.rawTokenOrdinal,
                    event.replayFingerprint
                ])
            }

            for conversationID in changedConversationIDs {
                try Self.removeReplayedUsage(
                    database: database,
                    changedConversationID: conversationID
                )
            }

            let cumulative = batch.nextState.lastCumulative ?? .zero
            try database.execute(
                sql: """
                    INSERT INTO ingest_checkpoints (
                        source_id, file_identity, canonical_path_hash, byte_offset,
                        last_complete_line_at, current_model, has_cumulative,
                        last_input_tokens, last_cached_input_tokens,
                        last_cache_write_tokens, last_output_tokens,
                        last_reasoning_tokens, last_total_tokens, raw_token_count,
                        last_raw_cumulative_total
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_id, file_identity) DO UPDATE SET
                        canonical_path_hash = excluded.canonical_path_hash,
                        byte_offset = excluded.byte_offset,
                        last_complete_line_at = excluded.last_complete_line_at,
                        current_model = excluded.current_model,
                        has_cumulative = excluded.has_cumulative,
                        last_input_tokens = excluded.last_input_tokens,
                        last_cached_input_tokens = excluded.last_cached_input_tokens,
                        last_cache_write_tokens = excluded.last_cache_write_tokens,
                        last_output_tokens = excluded.last_output_tokens,
                        last_reasoning_tokens = excluded.last_reasoning_tokens,
                        last_total_tokens = excluded.last_total_tokens,
                        raw_token_count = excluded.raw_token_count,
                        last_raw_cumulative_total = excluded.last_raw_cumulative_total
                    """,
                arguments: [
                    "codex",
                    fileIdentity,
                    canonicalPathHash,
                    Int64(clamping: batch.nextState.byteOffset),
                    Date(),
                    batch.nextState.currentModel,
                    batch.nextState.lastCumulative != nil,
                    cumulative.inputTokens,
                    cumulative.cachedInputTokens,
                    cumulative.cacheWriteTokens,
                    cumulative.outputTokens,
                    cumulative.reasoningTokens,
                    cumulative.totalTokens,
                    batch.nextState.rawTokenCount,
                    batch.nextState.lastRawCumulativeTotal
                ]
            )
        }
    }

    func persistLocalEvents(
        _ events: [LocalUsageEvent],
        sourceIdentifier: String,
        sourceDisplayName: String,
        sourceKind: String,
        accuracy: UsageAccuracy,
        allowDecreasingTotals: Bool = false,
        checkpoint: LocalFileCheckpoint? = nil,
        fileIdentity: String? = nil,
        canonicalPathHash: String? = nil
    ) throws {
        precondition(
            checkpoint == nil || (fileIdentity != nil && canonicalPathHash != nil),
            "A checkpoint requires a file identity and canonical path hash"
        )

        try database.writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO usage_sources (id, kind, display_name, status, accuracy, last_scan_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind = excluded.kind,
                        display_name = excluded.display_name,
                        status = excluded.status,
                        accuracy = excluded.accuracy,
                        last_scan_at = excluded.last_scan_at,
                        last_error_code = NULL
                    """,
                arguments: [
                    sourceIdentifier,
                    sourceKind,
                    sourceDisplayName,
                    "online",
                    accuracy.rawValue,
                    Date()
                ]
            )

            let upsertConversation = try database.makeStatement(sql: """
                INSERT INTO conversations (
                    id, source_id, external_session_hash, model_id, project_label,
                    started_at, last_event_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    model_id = COALESCE(excluded.model_id, conversations.model_id),
                    project_label = COALESCE(excluded.project_label, conversations.project_label),
                    started_at = CASE
                        WHEN conversations.started_at IS NULL OR excluded.started_at < conversations.started_at
                        THEN excluded.started_at ELSE conversations.started_at END,
                    last_event_at = CASE
                        WHEN conversations.last_event_at IS NULL OR excluded.last_event_at > conversations.last_event_at
                        THEN excluded.last_event_at ELSE conversations.last_event_at END
                """)
            let decreasingTotalCondition = allowDecreasingTotals
                ? ""
                : "WHERE excluded.total_tokens >= usage_events.total_tokens"
            let upsertEvent = try database.makeStatement(sql: """
                INSERT INTO usage_events (
                    idempotency_key, conversation_id, occurred_at, model_id,
                    input_tokens, cached_input_tokens, cache_write_tokens,
                    output_tokens, reasoning_tokens, total_tokens,
                    accuracy, raw_schema_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(idempotency_key) DO UPDATE SET
                    conversation_id = excluded.conversation_id,
                    occurred_at = excluded.occurred_at,
                    model_id = excluded.model_id,
                    input_tokens = excluded.input_tokens,
                    cached_input_tokens = excluded.cached_input_tokens,
                    cache_write_tokens = excluded.cache_write_tokens,
                    output_tokens = excluded.output_tokens,
                    reasoning_tokens = excluded.reasoning_tokens,
                    total_tokens = excluded.total_tokens,
                    accuracy = excluded.accuracy,
                    raw_schema_version = excluded.raw_schema_version
                \(decreasingTotalCondition)
                """)

            for event in events {
                let conversationID = "\(sourceIdentifier):\(event.sessionIdentifier)"
                try upsertConversation.execute(arguments: [
                    conversationID,
                    sourceIdentifier,
                    event.sessionIdentifier,
                    event.model,
                    event.projectLabel,
                    event.occurredAt,
                    event.occurredAt
                ])
                try upsertEvent.execute(arguments: [
                    event.idempotencyKey,
                    conversationID,
                    event.occurredAt,
                    event.model,
                    event.counters.inputTokens,
                    event.counters.cachedInputTokens,
                    event.counters.cacheWriteTokens,
                    event.counters.outputTokens,
                    event.counters.reasoningTokens,
                    event.counters.totalTokens,
                    accuracy.rawValue,
                    event.rawSchemaVersion
                ])
            }

            if let checkpoint, let fileIdentity, let canonicalPathHash {
                try database.execute(
                    sql: """
                        INSERT INTO ingest_checkpoints (
                            source_id, file_identity, canonical_path_hash, byte_offset,
                            last_complete_line_at
                        ) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(source_id, file_identity) DO UPDATE SET
                            canonical_path_hash = excluded.canonical_path_hash,
                            byte_offset = excluded.byte_offset,
                            last_complete_line_at = excluded.last_complete_line_at
                        """,
                    arguments: [
                        sourceIdentifier,
                        fileIdentity,
                        canonicalPathHash,
                        Int64(clamping: checkpoint.byteOffset),
                        Date()
                    ]
                )
            }
        }
    }

    func latestConversationSnapshot() throws -> TokenUsageSnapshot? {
        try database.writer.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    WITH latest_conversation AS (
                        SELECT conversation_id
                        FROM usage_events
                        ORDER BY occurred_at DESC, idempotency_key DESC
                        LIMIT 1
                    )
                    SELECT conversations.source_id AS source_id,
                           conversations.external_session_hash AS session_id,
                           CASE WHEN COUNT(DISTINCT usage_events.model_id) = 1
                                THEN MAX(usage_events.model_id) ELSE NULL END AS model_id,
                           SUM(input_tokens) AS input_tokens,
                           SUM(cached_input_tokens) AS cached_input_tokens,
                           SUM(cache_write_tokens) AS cache_write_tokens,
                           SUM(output_tokens) AS output_tokens,
                           SUM(reasoning_tokens) AS reasoning_tokens,
                           SUM(total_tokens) AS total_tokens,
                           MAX(occurred_at) AS recorded_at,
                           CASE MAX(CASE usage_events.accuracy
                               WHEN 'credits' THEN 3
                               WHEN 'estimated' THEN 2
                               WHEN 'derived' THEN 1
                               ELSE 0 END)
                               WHEN 3 THEN 'credits'
                               WHEN 2 THEN 'estimated'
                               WHEN 1 THEN 'derived'
                               ELSE 'exact' END AS accuracy
                    FROM usage_events
                    JOIN latest_conversation
                      ON latest_conversation.conversation_id = usage_events.conversation_id
                    JOIN conversations ON conversations.id = usage_events.conversation_id
                    GROUP BY conversations.source_id, conversations.external_session_hash
                    """
            ) else {
                return nil
            }
            return TokenUsageSnapshot(
                source: row["source_id"],
                model: row["model_id"],
                sessionIdentifier: row["session_id"],
                inputTokens: row["input_tokens"],
                cachedInputTokens: row["cached_input_tokens"],
                cacheWriteTokens: row["cache_write_tokens"],
                outputTokens: row["output_tokens"],
                reasoningTokens: row["reasoning_tokens"],
                totalTokens: row["total_tokens"],
                recordedAt: row["recorded_at"],
                accuracy: Self.accuracy(row["accuracy"])
            )
        }
    }

    func aggregate(source: String?, from startDate: Date, through endDate: Date) throws -> UsageAggregation {
        try database.writer.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT conversations.source_id AS source_id,
                           usage_sources.display_name AS source_display_name,
                           usage_events.model_id AS model_id,
                           SUM(input_tokens) AS input_tokens,
                           SUM(cached_input_tokens) AS cached_input_tokens,
                           SUM(cache_write_tokens) AS cache_write_tokens,
                           SUM(output_tokens) AS output_tokens,
                           SUM(reasoning_tokens) AS reasoning_tokens,
                           SUM(total_tokens) AS total_tokens,
                           MAX(occurred_at) AS recorded_at,
                           CASE MAX(CASE usage_events.accuracy
                               WHEN 'credits' THEN 3
                               WHEN 'estimated' THEN 2
                               WHEN 'derived' THEN 1
                               ELSE 0 END)
                               WHEN 3 THEN 'credits'
                               WHEN 2 THEN 'estimated'
                               WHEN 1 THEN 'derived'
                               ELSE 'exact' END AS accuracy
                    FROM usage_events
                    JOIN conversations ON conversations.id = usage_events.conversation_id
                    JOIN usage_sources ON usage_sources.id = conversations.source_id
                    WHERE (? IS NULL OR conversations.source_id = ?)
                      AND occurred_at >= ? AND occurred_at <= ?
                    GROUP BY conversations.source_id, usage_sources.display_name, usage_events.model_id
                    ORDER BY total_tokens DESC, conversations.source_id, usage_events.model_id
                    """,
                arguments: [source, source, startDate, endDate]
            )
            let sessionCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(DISTINCT conversation_id)
                    FROM usage_events
                    JOIN conversations ON conversations.id = usage_events.conversation_id
                    WHERE (? IS NULL OR conversations.source_id = ?)
                      AND occurred_at >= ? AND occurred_at <= ?
                    """,
                arguments: [source, source, startDate, endDate]
            ) ?? 0

            let sourceModelSnapshots = rows.map { row in
                let sourceIdentifier: String = row["source_id"]
                return TokenUsageSnapshot(
                    source: sourceIdentifier,
                    model: row["model_id"],
                    sessionIdentifier: "aggregate",
                    inputTokens: row["input_tokens"],
                    cachedInputTokens: row["cached_input_tokens"],
                    cacheWriteTokens: row["cache_write_tokens"],
                    outputTokens: row["output_tokens"],
                    reasoningTokens: row["reasoning_tokens"],
                    totalTokens: row["total_tokens"],
                    recordedAt: row["recorded_at"],
                    accuracy: Self.accuracy(row["accuracy"])
                )
            }
            let aggregateSource = source ?? "all"
            let modelSnapshots = Self.combineByModel(
                sourceModelSnapshots,
                aggregateSource: aggregateSource
            )
            guard !modelSnapshots.isEmpty else { return .empty }

            let sourceRows = Dictionary(grouping: rows) { row -> String in
                row["source_id"]
            }
            let sourceBreakdowns = sourceRows.map { sourceIdentifier, groupedRows in
                let displayName: String = groupedRows.first?["source_display_name"] ?? sourceIdentifier
                return UsageSourceBreakdown(
                    sourceIdentifier: sourceIdentifier,
                    displayName: displayName,
                    modelSnapshots: sourceModelSnapshots.filter { $0.source == sourceIdentifier }
                )
            }.sorted { left, right in
                let leftTotal = left.modelSnapshots.reduce(Int64(0)) {
                    Self.saturatingAdd($0, $1.totalTokens)
                }
                let rightTotal = right.modelSnapshots.reduce(Int64(0)) {
                    Self.saturatingAdd($0, $1.totalTokens)
                }
                if leftTotal == rightTotal {
                    return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
                }
                return leftTotal > rightTotal
            }

            let total = modelSnapshots.reduce(TokenUsageCounters.zero) { partial, snapshot in
                TokenUsageCounters(
                    inputTokens: Self.saturatingAdd(partial.inputTokens, snapshot.inputTokens),
                    cachedInputTokens: Self.saturatingAdd(partial.cachedInputTokens, snapshot.cachedInputTokens),
                    cacheWriteTokens: Self.saturatingAdd(partial.cacheWriteTokens, snapshot.cacheWriteTokens),
                    outputTokens: Self.saturatingAdd(partial.outputTokens, snapshot.outputTokens),
                    reasoningTokens: Self.saturatingAdd(partial.reasoningTokens, snapshot.reasoningTokens),
                    totalTokens: Self.saturatingAdd(partial.totalTokens, snapshot.totalTokens)
                )
            }
            let latestDate = modelSnapshots.map(\.recordedAt).max() ?? endDate
            let aggregateSnapshot = TokenUsageSnapshot(
                source: aggregateSource,
                model: modelSnapshots.count == 1 ? modelSnapshots[0].model : nil,
                sessionIdentifier: "aggregate",
                inputTokens: total.inputTokens,
                cachedInputTokens: total.cachedInputTokens,
                cacheWriteTokens: total.cacheWriteTokens,
                outputTokens: total.outputTokens,
                reasoningTokens: total.reasoningTokens,
                totalTokens: total.totalTokens,
                recordedAt: latestDate,
                accuracy: Self.combinedAccuracy(modelSnapshots)
            )
            return UsageAggregation(
                snapshot: aggregateSnapshot,
                modelSnapshots: modelSnapshots,
                sourceBreakdowns: sourceBreakdowns,
                sessionCount: sessionCount
            )
        }
    }

    func trend(
        source: String?,
        intervals: [UsageTrendInterval],
        granularity: UsageTrendGranularity
    ) throws -> UsageTrendSeries {
        guard !intervals.isEmpty else {
            return UsageTrendSeries(granularity: granularity, buckets: [])
        }

        return try database.writer.read { database in
            let values = intervals.indices.map { _ in "(?, ?, ?, ?)" }.joined(separator: ", ")
            var arguments = StatementArguments()
            for (index, interval) in intervals.enumerated() {
                arguments += [
                    index,
                    interval.rangeStart,
                    interval.rangeEnd,
                    index == intervals.indices.last ? 1 : 0
                ]
            }
            arguments += [source, source]

            let rows = try Row.fetchAll(
                database,
                sql: """
                    WITH buckets(bucket_index, start_at, end_at, includes_end) AS (
                        VALUES \(values)
                    )
                    SELECT buckets.bucket_index AS bucket_index,
                           usage_events.model_id AS model_id,
                           SUM(input_tokens) AS input_tokens,
                           SUM(cached_input_tokens) AS cached_input_tokens,
                           SUM(cache_write_tokens) AS cache_write_tokens,
                           SUM(output_tokens) AS output_tokens,
                           SUM(reasoning_tokens) AS reasoning_tokens,
                           SUM(total_tokens) AS total_tokens,
                           MAX(occurred_at) AS recorded_at,
                           CASE MAX(CASE usage_events.accuracy
                               WHEN 'credits' THEN 3
                               WHEN 'estimated' THEN 2
                               WHEN 'derived' THEN 1
                               ELSE 0 END)
                               WHEN 3 THEN 'credits'
                               WHEN 2 THEN 'estimated'
                               WHEN 1 THEN 'derived'
                               ELSE 'exact' END AS accuracy
                    FROM buckets
                    JOIN usage_events
                      ON usage_events.occurred_at >= buckets.start_at
                     AND (
                         usage_events.occurred_at < buckets.end_at
                         OR (buckets.includes_end = 1 AND usage_events.occurred_at = buckets.end_at)
                     )
                    JOIN conversations ON conversations.id = usage_events.conversation_id
                    WHERE (? IS NULL OR conversations.source_id = ?)
                    GROUP BY buckets.bucket_index, usage_events.model_id
                    ORDER BY buckets.bucket_index, total_tokens DESC, usage_events.model_id
                    """,
                arguments: arguments
            )
            let rowsByBucket = Dictionary(grouping: rows) { row -> Int in
                row["bucket_index"]
            }
            let aggregateSource = source ?? "all"
            let buckets = intervals.enumerated().map { index, interval in
                let snapshots = (rowsByBucket[index] ?? []).map { row in
                    TokenUsageSnapshot(
                        source: aggregateSource,
                        model: row["model_id"],
                        sessionIdentifier: "trend",
                        inputTokens: row["input_tokens"],
                        cachedInputTokens: row["cached_input_tokens"],
                        cacheWriteTokens: row["cache_write_tokens"],
                        outputTokens: row["output_tokens"],
                        reasoningTokens: row["reasoning_tokens"],
                        totalTokens: row["total_tokens"],
                        recordedAt: row["recorded_at"],
                        accuracy: Self.accuracy(row["accuracy"])
                    )
                }
                return UsageTrendBucket(
                    bucketStart: interval.bucketStart,
                    modelSnapshots: snapshots
                )
            }
            return UsageTrendSeries(granularity: granularity, buckets: buckets)
        }
    }

    private static func combineByModel(
        _ snapshots: [TokenUsageSnapshot],
        aggregateSource: String
    ) -> [TokenUsageSnapshot] {
        Dictionary(grouping: snapshots) { $0.model ?? "" }
            .map { modelIdentifier, groupedSnapshots in
                let counters = groupedSnapshots.reduce(TokenUsageCounters.zero) { partial, snapshot in
                    TokenUsageCounters(
                        inputTokens: saturatingAdd(partial.inputTokens, snapshot.inputTokens),
                        cachedInputTokens: saturatingAdd(partial.cachedInputTokens, snapshot.cachedInputTokens),
                        cacheWriteTokens: saturatingAdd(partial.cacheWriteTokens, snapshot.cacheWriteTokens),
                        outputTokens: saturatingAdd(partial.outputTokens, snapshot.outputTokens),
                        reasoningTokens: saturatingAdd(partial.reasoningTokens, snapshot.reasoningTokens),
                        totalTokens: saturatingAdd(partial.totalTokens, snapshot.totalTokens)
                    )
                }
                return TokenUsageSnapshot(
                    source: aggregateSource,
                    model: modelIdentifier.isEmpty ? nil : modelIdentifier,
                    sessionIdentifier: "aggregate",
                    inputTokens: counters.inputTokens,
                    cachedInputTokens: counters.cachedInputTokens,
                    cacheWriteTokens: counters.cacheWriteTokens,
                    outputTokens: counters.outputTokens,
                    reasoningTokens: counters.reasoningTokens,
                    totalTokens: counters.totalTokens,
                    recordedAt: groupedSnapshots.map(\.recordedAt).max() ?? .distantPast,
                    accuracy: combinedAccuracy(groupedSnapshots)
                )
            }
            .sorted { left, right in
                if left.totalTokens == right.totalTokens {
                    return (left.model ?? "").localizedStandardCompare(right.model ?? "") == .orderedAscending
                }
                return left.totalTokens > right.totalTokens
            }
    }

    private static func accuracy(_ rawValue: String?) -> UsageAccuracy {
        rawValue.flatMap(UsageAccuracy.init(rawValue:)) ?? .exact
    }

    private static func combinedAccuracy(
        _ snapshots: [TokenUsageSnapshot]
    ) -> UsageAccuracy {
        snapshots.map(\.accuracy).max { accuracyRank($0) < accuracyRank($1) } ?? .exact
    }

    private static func accuracyRank(_ accuracy: UsageAccuracy) -> Int {
        switch accuracy {
        case .exact: 0
        case .derived: 1
        case .estimated: 2
        case .credits: 3
        }
    }

    private static func removeReplayedUsage(
        database: Database,
        changedConversationID: String
    ) throws {
        guard let changed = try Row.fetchOne(
            database,
            sql: """
                SELECT canonical_session_hash
                FROM conversations
                WHERE id = ?
                """,
            arguments: [changedConversationID]
        ) else {
            return
        }

        var candidateIDs = [changedConversationID]
        let canonicalSessionHash: String? = changed["canonical_session_hash"]
        if let canonicalSessionHash {
            candidateIDs.append(contentsOf: try String.fetchAll(
                database,
                sql: """
                    SELECT id FROM conversations
                    WHERE parent_session_hash = ? OR forked_from_session_hash = ?
                    """,
                arguments: [canonicalSessionHash, canonicalSessionHash]
            ))
        }

        for conversationID in Set(candidateIDs) {
            try removeReplayedUsage(database: database, conversationID: conversationID)
        }
    }

    private static func removeReplayedUsage(
        database: Database,
        conversationID: String
    ) throws {
        guard let child = try Row.fetchOne(
            database,
            sql: """
                SELECT parent_session_hash, forked_from_session_hash,
                       session_created_at, is_subagent, replay_token_count
                FROM conversations
                WHERE id = ?
                """,
            arguments: [conversationID]
        ) else {
            return
        }

        let forkedFromHash: String? = child["forked_from_session_hash"]
        let parentHash: String? = child["parent_session_hash"]
        guard let sourceHash = forkedFromHash ?? parentHash,
              let parentConversationID = try String.fetchOne(
                database,
                sql: "SELECT id FROM conversations WHERE canonical_session_hash = ? LIMIT 1",
                arguments: [sourceHash]
              ) else {
            return
        }

        let childFingerprints = try String.fetchAll(
            database,
            sql: """
                SELECT replay_fingerprint
                FROM codex_raw_token_records
                WHERE conversation_id = ?
                ORDER BY raw_token_ordinal
                """,
            arguments: [conversationID]
        )
        guard !childFingerprints.isEmpty else { return }

        let createdAt: Date? = child["session_created_at"]
        let parentFingerprints: [String]
        if let createdAt {
            parentFingerprints = try String.fetchAll(
                database,
                sql: """
                    SELECT replay_fingerprint
                    FROM codex_raw_token_records
                    WHERE conversation_id = ? AND occurred_at <= ?
                    ORDER BY raw_token_ordinal
                    """,
                arguments: [parentConversationID, createdAt]
            )
        } else {
            parentFingerprints = try String.fetchAll(
                database,
                sql: """
                    SELECT replay_fingerprint
                    FROM codex_raw_token_records
                    WHERE conversation_id = ?
                    ORDER BY raw_token_ordinal
                    """,
                arguments: [parentConversationID]
            )
        }
        guard !parentFingerprints.isEmpty else { return }

        let exactPrefix = longestReplayPrefix(
            child: childFingerprints,
            parent: parentFingerprints
        )
        let isSubagent: Bool = child["is_subagent"]
        let partialPrefix = isSubagent
            ? longestPartialReplayPrefix(child: childFingerprints, parent: parentFingerprints)
            : 0
        let storedBoundary: Int64 = child["replay_token_count"]
        let boundary = max(storedBoundary, Int64(max(exactPrefix, partialPrefix)))
        guard boundary > 0 else { return }

        try database.execute(
            sql: "UPDATE conversations SET replay_token_count = ? WHERE id = ?",
            arguments: [boundary, conversationID]
        )
        try database.execute(
            sql: """
                DELETE FROM usage_events
                WHERE conversation_id = ? AND raw_token_ordinal <= ?
                """,
            arguments: [conversationID, boundary]
        )
    }

    private static func longestReplayPrefix(child: [String], parent: [String]) -> Int {
        guard !child.isEmpty, !parent.isEmpty else { return 0 }
        let prefix = prefixTable(for: child)
        var matched = 0
        for (index, fingerprint) in parent.enumerated() {
            while matched > 0, fingerprint != child[matched] {
                matched = prefix[matched - 1]
            }
            if fingerprint == child[matched] {
                matched += 1
            }
            if matched == child.count, index < parent.count - 1 {
                matched = prefix[matched - 1]
            }
        }
        return matched
    }

    private static func longestPartialReplayPrefix(child: [String], parent: [String]) -> Int {
        guard !child.isEmpty, !parent.isEmpty else { return 0 }
        let prefix = prefixTable(for: child)
        var matched = 0
        var longest = 0
        for fingerprint in parent {
            while matched > 0, fingerprint != child[matched] {
                matched = prefix[matched - 1]
            }
            if fingerprint == child[matched] {
                matched += 1
            }
            longest = max(longest, matched)
            if matched == child.count {
                matched = prefix[matched - 1]
            }
        }
        return longest
    }

    private static func prefixTable(for values: [String]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var prefix = Array(repeating: 0, count: values.count)
        var matched = 0
        for index in 1..<values.count {
            while matched > 0, values[index] != values[matched] {
                matched = prefix[matched - 1]
            }
            if values[index] == values[matched] {
                matched += 1
            }
            prefix[index] = matched
        }
        return prefix
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

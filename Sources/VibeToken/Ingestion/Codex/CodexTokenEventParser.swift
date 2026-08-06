import CryptoKit
import Foundation

struct CodexTokenEventParser: Sendable {
    private struct TimestampParser {
        private let fractional: ISO8601DateFormatter
        private let standard: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            standard = ISO8601DateFormatter()
        }

        func parse(_ value: String?) -> Date? {
            guard let value else { return nil }
            return fractional.date(from: value) ?? standard.date(from: value)
        }
    }

    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let turnContextMarker = Data("\"turn_context\"".utf8)
    private static let sessionMetaMarker = Data("\"session_meta\"".utf8)

    private struct Envelope: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let model: String?
        let info: UsageInfo?
    }

    private struct UsageInfo: Decodable {
        let totalTokenUsage: RawUsage?
        let lastTokenUsage: RawUsage?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
        }
    }

    private struct RawUsage: Decodable {
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let cacheWriteInputTokens: Int64
        let outputTokens: Int64
        let reasoningOutputTokens: Int64
        let totalTokens: Int64

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheWriteInputTokens = "cache_write_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    func parseLatestUsage(in fileURL: URL, maximumTailBytes: Int) throws -> TokenUsageSnapshot? {
        let handle = try openHandle(fileURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else { return nil }
        let requestedBytes = UInt64(max(maximumTailBytes, 1_024))
        let startOffset = fileSize > requestedBytes ? fileSize - requestedBytes : 0
        try handle.seek(toOffset: startOffset)

        guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startOffset > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        let decoder = JSONDecoder()
        let timestampParser = TimestampParser()
        var latestUsage: (RawUsage, Date?)?
        var model: String?
        for line in lines.reversed() {
            guard Self.isUsageOrModelLine(line),
                  let envelope = try? decoder.decode(Envelope.self, from: Data(line)) else {
                continue
            }
            if model == nil, let candidate = envelope.payload?.model, !candidate.isEmpty {
                model = candidate
            }
            if latestUsage == nil,
               envelope.type == "event_msg",
               envelope.payload?.type == "token_count",
               let usage = envelope.payload?.info?.totalTokenUsage {
                latestUsage = (usage, timestampParser.parse(envelope.timestamp))
            }
            if latestUsage != nil, model != nil {
                break
            }
        }

        guard let (usage, timestamp) = latestUsage else { return nil }
        return Self.snapshot(
            counters: Self.normalize(usage),
            model: model,
            sessionIdentifier: Self.sessionIdentifier(for: fileURL),
            recordedAt: timestamp ?? Date()
        )
    }

    func parseIncrementalUsage(
        in fileURL: URL,
        sessionIdentifier: String,
        initialState: CodexParserState,
        chunkBytes: Int,
        maximumLineBytes: Int
    ) throws -> CodexParseBatch {
        let handle = try openHandle(fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: initialState.byteOffset)

        let decoder = JSONDecoder()
        let timestampParser = TimestampParser()
        let chunkSize = max(64 * 1_024, chunkBytes)
        let lineLimit = max(64 * 1_024, maximumLineBytes)
        var model = initialState.currentModel
        var cumulative = initialState.lastCumulative
        var rawCumulativeTotal = initialState.lastRawCumulativeTotal
        var rawTokenCount = initialState.rawTokenCount
        var latestSnapshot: TokenUsageSnapshot?
        var events: [CodexUsageEvent] = []
        var rawTokenRecords: [CodexRawTokenRecord] = []
        var sessionMetadata: CodexSessionMetadata?
        var lineBuffer = Data()
        var discardingOversizedLine = false
        var streamOffset = initialState.byteOffset
        var committedOffset = initialState.byteOffset

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            let chunkStartOffset = streamOffset
            streamOffset += UInt64(chunk.count)
            var segmentStart = chunk.startIndex

            while let newlineIndex = chunk[segmentStart...].firstIndex(of: 0x0A) {
                let segment = chunk[segmentStart..<newlineIndex]
                if !discardingOversizedLine {
                    if lineBuffer.count + segment.count <= lineLimit {
                        lineBuffer.append(contentsOf: segment)
                        process(
                            line: lineBuffer,
                            decoder: decoder,
                            timestampParser: timestampParser,
                            sessionIdentifier: sessionIdentifier,
                            model: &model,
                            cumulative: &cumulative,
                            rawCumulativeTotal: &rawCumulativeTotal,
                            rawTokenCount: &rawTokenCount,
                            latestSnapshot: &latestSnapshot,
                            events: &events,
                            rawTokenRecords: &rawTokenRecords,
                            sessionMetadata: &sessionMetadata
                        )
                    } else {
                        discardingOversizedLine = true
                    }
                }

                lineBuffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
                let consumedInChunk = chunk.distance(from: chunk.startIndex, to: newlineIndex) + 1
                committedOffset = chunkStartOffset + UInt64(consumedInChunk)
                segmentStart = chunk.index(after: newlineIndex)
            }

            let remainder = chunk[segmentStart...]
            if !remainder.isEmpty, !discardingOversizedLine {
                if lineBuffer.count + remainder.count <= lineLimit {
                    lineBuffer.append(contentsOf: remainder)
                } else {
                    lineBuffer.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                }
            }
        }

        return CodexParseBatch(
            events: events,
            nextState: CodexParserState(
                byteOffset: committedOffset,
                currentModel: model,
                lastCumulative: cumulative,
                lastRawCumulativeTotal: rawCumulativeTotal,
                rawTokenCount: rawTokenCount
            ),
            latestSnapshot: latestSnapshot,
            rawTokenRecords: rawTokenRecords,
            sessionMetadata: sessionMetadata
        )
    }

    static func sessionIdentifier(for fileURL: URL) -> String {
        hash(fileURL.lastPathComponent)
    }

    static func pathHash(for fileURL: URL) -> String {
        hash(fileURL.standardizedFileURL.path)
    }

    private func openHandle(_ fileURL: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw AppError.permissionDenied
        } catch {
            throw AppError.unreadableFile
        }
    }

    private func process(
        line: Data,
        decoder: JSONDecoder,
        timestampParser: TimestampParser,
        sessionIdentifier: String,
        model: inout String?,
        cumulative: inout TokenUsageCounters?,
        rawCumulativeTotal: inout Int64?,
        rawTokenCount: inout Int64,
        latestSnapshot: inout TokenUsageSnapshot?,
        events: inout [CodexUsageEvent],
        rawTokenRecords: inout [CodexRawTokenRecord],
        sessionMetadata: inout CodexSessionMetadata?
    ) {
        guard !line.isEmpty, Self.isUsageOrModelLine(line),
              let envelope = try? decoder.decode(Envelope.self, from: line) else {
            return
        }

        if let candidate = envelope.payload?.model, !candidate.isEmpty {
            model = candidate
        }
        if envelope.type == "session_meta", sessionMetadata == nil {
            sessionMetadata = Self.sessionMetadata(
                from: line,
                fallbackTimestamp: timestampParser.parse(envelope.timestamp)
            )
        }
        guard envelope.type == "event_msg",
              envelope.payload?.type == "token_count" else {
            return
        }

        rawTokenCount = Self.saturatingAdd(rawTokenCount, 1)
        let occurredAt = timestampParser.parse(envelope.timestamp)
        let replayFingerprint = Self.replayFingerprint(from: line)
        if let replayFingerprint {
            rawTokenRecords.append(CodexRawTokenRecord(
                rawTokenOrdinal: rawTokenCount,
                replayFingerprint: replayFingerprint,
                occurredAt: occurredAt
            ))
        }

        guard let info = envelope.payload?.info,
              let rawCumulative = info.totalTokenUsage,
              let occurredAt else {
            return
        }

        let normalizedCumulative = Self.normalize(rawCumulative)
        let isDuplicateEmission = rawCumulative.totalTokens > 0
            && rawCumulative.totalTokens == rawCumulativeTotal
        let delta = info.lastTokenUsage.map(Self.normalize)
            ?? normalizedCumulative.delta(from: cumulative)
        cumulative = normalizedCumulative
        rawCumulativeTotal = rawCumulative.totalTokens
        latestSnapshot = Self.snapshot(
            counters: normalizedCumulative,
            model: model,
            sessionIdentifier: sessionIdentifier,
            recordedAt: occurredAt
        )
        guard !isDuplicateEmission, !delta.isZero else { return }

        events.append(CodexUsageEvent(
            idempotencyKey: Self.eventIdentifier(
                sessionIdentifier: sessionIdentifier,
                timestamp: envelope.timestamp ?? "",
                cumulative: normalizedCumulative
            ),
            sessionIdentifier: sessionIdentifier,
            model: model,
            occurredAt: occurredAt,
            counters: delta,
            rawTokenOrdinal: rawTokenCount,
            replayFingerprint: replayFingerprint
        ))
    }

    private static func sessionMetadata(
        from line: Data,
        fallbackTimestamp: Date?
    ) -> CodexSessionMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        let sessionID = nonEmptyString(payload["id"])
        let forkedFromID = nonEmptyString(payload["forked_from_id"])
        let directParentID = nonEmptyString(payload["parent_thread_id"])
        let source = payload["source"]
        let sourceObject = source as? [String: Any]
        let subagentObject = sourceObject?["subagent"] as? [String: Any]
        let spawnObject = subagentObject?["thread_spawn"] as? [String: Any]
        let nestedParentID = nonEmptyString(spawnObject?["parent_thread_id"])
        let parentID = directParentID ?? nestedParentID
        let isSubagent = nonEmptyString(payload["thread_source"]) == "subagent"
            || nonEmptyString(source) == "subagent"
            || subagentObject != nil
            || parentID != nil

        let createdAt = nonEmptyString(payload["timestamp"])
            .flatMap { TimestampParser().parse($0) } ?? fallbackTimestamp
        return CodexSessionMetadata(
            sessionHash: sessionID.map(hash),
            parentSessionHash: parentID.map(hash),
            forkedFromSessionHash: forkedFromID.map(hash),
            createdAt: createdAt,
            isSubagent: isSubagent
        )
    }

    private static func replayFingerprint(from line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"],
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return hash(data)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalize(_ usage: RawUsage) -> TokenUsageCounters {
        let input = max(0, usage.inputTokens)
        let cached = min(input, max(0, usage.cachedInputTokens))
        let afterCached = input - cached
        let cacheWrite = min(afterCached, max(0, usage.cacheWriteInputTokens))
        let nonCachedInput = afterCached - cacheWrite

        let output = max(0, usage.outputTokens)
        let reasoning = min(output, max(0, usage.reasoningOutputTokens))
        let visibleOutput = output - reasoning
        let fallbackTotal = saturatingAdd(input, output)

        return TokenUsageCounters(
            inputTokens: nonCachedInput,
            cachedInputTokens: cached,
            cacheWriteTokens: cacheWrite,
            outputTokens: visibleOutput,
            reasoningTokens: reasoning,
            totalTokens: usage.totalTokens > 0 ? usage.totalTokens : fallbackTotal
        )
    }

    private static func snapshot(
        counters: TokenUsageCounters,
        model: String?,
        sessionIdentifier: String,
        recordedAt: Date
    ) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            source: "codex",
            model: model,
            sessionIdentifier: sessionIdentifier,
            inputTokens: counters.inputTokens,
            cachedInputTokens: counters.cachedInputTokens,
            cacheWriteTokens: counters.cacheWriteTokens,
            outputTokens: counters.outputTokens,
            reasoningTokens: counters.reasoningTokens,
            totalTokens: counters.totalTokens,
            recordedAt: recordedAt,
            accuracy: .exact
        )
    }

    private static func isUsageOrModelLine<T: DataProtocol>(_ line: T) -> Bool {
        let data = Data(line)
        return data.range(of: tokenCountMarker) != nil
            || data.range(of: turnContextMarker) != nil
            || data.range(of: sessionMetaMarker) != nil
    }

    private static func eventIdentifier(
        sessionIdentifier: String,
        timestamp: String,
        cumulative: TokenUsageCounters
    ) -> String {
        hash("""
            \(sessionIdentifier)|\(timestamp)|\(cumulative.inputTokens)|\(cumulative.cachedInputTokens)|\
            \(cumulative.cacheWriteTokens)|\(cumulative.outputTokens)|\(cumulative.reasoningTokens)|\
            \(cumulative.totalTokens)
            """)
    }

    private static func hash(_ value: String) -> String {
        hash(Data(value.utf8))
    }

    private static func hash(_ value: Data) -> String {
        let digest = SHA256.hash(data: value)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

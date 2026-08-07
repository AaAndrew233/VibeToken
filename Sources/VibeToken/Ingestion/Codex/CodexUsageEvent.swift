import Foundation

struct TokenUsageCounters: Equatable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let totalTokens: Int64

    static let zero = TokenUsageCounters(
        inputTokens: 0,
        cachedInputTokens: 0,
        cacheWriteTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        totalTokens: 0
    )

    var isZero: Bool {
        inputTokens == 0
            && cachedInputTokens == 0
            && cacheWriteTokens == 0
            && outputTokens == 0
            && reasoningTokens == 0
            && totalTokens == 0
    }

    func delta(from previous: TokenUsageCounters?) -> TokenUsageCounters {
        guard let previous else { return self }
        return TokenUsageCounters(
            inputTokens: Self.monotonicDelta(inputTokens, previous.inputTokens),
            cachedInputTokens: Self.monotonicDelta(cachedInputTokens, previous.cachedInputTokens),
            cacheWriteTokens: Self.monotonicDelta(cacheWriteTokens, previous.cacheWriteTokens),
            outputTokens: Self.monotonicDelta(outputTokens, previous.outputTokens),
            reasoningTokens: Self.monotonicDelta(reasoningTokens, previous.reasoningTokens),
            totalTokens: Self.monotonicDelta(totalTokens, previous.totalTokens)
        )
    }

    private static func monotonicDelta(_ current: Int64, _ previous: Int64) -> Int64 {
        current >= previous ? current - previous : current
    }
}

struct CodexUsageEvent: Equatable, Sendable {
    let idempotencyKey: String
    let sessionIdentifier: String
    let model: String?
    let occurredAt: Date
    let counters: TokenUsageCounters
    let rawTokenOrdinal: Int64?
    let replayFingerprint: String?

    init(
        idempotencyKey: String,
        sessionIdentifier: String,
        model: String?,
        occurredAt: Date,
        counters: TokenUsageCounters,
        rawTokenOrdinal: Int64? = nil,
        replayFingerprint: String? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.sessionIdentifier = sessionIdentifier
        self.model = model
        self.occurredAt = occurredAt
        self.counters = counters
        self.rawTokenOrdinal = rawTokenOrdinal
        self.replayFingerprint = replayFingerprint
    }
}

struct CodexRawTokenRecord: Equatable, Sendable {
    let rawTokenOrdinal: Int64
    let replayFingerprint: String
    let occurredAt: Date?
}

struct CodexSessionMetadata: Equatable, Sendable {
    let sessionHash: String?
    let parentSessionHash: String?
    let forkedFromSessionHash: String?
    let createdAt: Date?
    let isSubagent: Bool
}

struct CodexParserState: Equatable, Sendable {
    let byteOffset: UInt64
    let currentModel: String?
    let lastCumulative: TokenUsageCounters?
    let lastRawCumulativeTotal: Int64?
    let rawTokenCount: Int64

    init(
        byteOffset: UInt64,
        currentModel: String?,
        lastCumulative: TokenUsageCounters?,
        lastRawCumulativeTotal: Int64? = nil,
        rawTokenCount: Int64 = 0
    ) {
        self.byteOffset = byteOffset
        self.currentModel = currentModel
        self.lastCumulative = lastCumulative
        self.lastRawCumulativeTotal = lastRawCumulativeTotal
        self.rawTokenCount = rawTokenCount
    }

    static let initial = CodexParserState(
        byteOffset: 0,
        currentModel: nil,
        lastCumulative: nil,
        lastRawCumulativeTotal: nil,
        rawTokenCount: 0
    )
}

struct CodexParseBatch: Equatable, Sendable {
    let events: [CodexUsageEvent]
    let nextState: CodexParserState
    let latestSnapshot: TokenUsageSnapshot?
    let rawTokenRecords: [CodexRawTokenRecord]
    let sessionMetadata: CodexSessionMetadata?

    init(
        events: [CodexUsageEvent],
        nextState: CodexParserState,
        latestSnapshot: TokenUsageSnapshot?,
        rawTokenRecords: [CodexRawTokenRecord] = [],
        sessionMetadata: CodexSessionMetadata? = nil
    ) {
        self.events = events
        self.nextState = nextState
        self.latestSnapshot = latestSnapshot
        self.rawTokenRecords = rawTokenRecords
        self.sessionMetadata = sessionMetadata
    }
}

typealias CodexWatchTargets = UsageWatchTargets

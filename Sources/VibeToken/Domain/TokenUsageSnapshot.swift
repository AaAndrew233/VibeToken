import Foundation

struct TokenUsageSnapshot: Equatable, Sendable {
    let source: String
    let model: String?
    let sessionIdentifier: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let totalTokens: Int64
    let recordedAt: Date
    let accuracy: UsageAccuracy
    let pricingContext: PricingContext

    init(
        source: String,
        model: String?,
        sessionIdentifier: String,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64,
        totalTokens: Int64,
        recordedAt: Date,
        accuracy: UsageAccuracy,
        pricingContext: PricingContext = .short
    ) {
        self.source = source
        self.model = model
        self.sessionIdentifier = sessionIdentifier
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.recordedAt = recordedAt
        self.accuracy = accuracy
        self.pricingContext = pricingContext
    }

    static let empty = TokenUsageSnapshot(
        source: "codex",
        model: nil,
        sessionIdentifier: "",
        inputTokens: 0,
        cachedInputTokens: 0,
        cacheWriteTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        totalTokens: 0,
        recordedAt: .distantPast,
        accuracy: .exact
    )
}

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

import Foundation

struct TokenPriceRate: Equatable, Sendable {
    let inputMicrosPerMillion: Int64
    let outputMicrosPerMillion: Int64
    let cachedInputMicrosPerMillion: Int64?
}

struct ModelPricingRule: Equatable, Sendable {
    let canonicalModel: String
    let standardRate: TokenPriceRate
    let tierRates: [String: TokenPriceRate]
    let effectiveFrom: Date?
    let effectiveUntil: Date?
}

struct MatchedModelPricing: Equatable, Sendable {
    let canonicalModel: String
    let tier: String?
    let rate: TokenPriceRate
    let catalogVersion: String
}

struct CostEstimate: Equatable, Sendable {
    let amount: MoneyAmount
    let matchedModel: String
    let tier: String?
    let catalogVersion: String
}

struct CostCoverageEstimate: Equatable, Sendable {
    let amount: MoneyAmount
    let pricedTokens: Int64
    let totalTokens: Int64
    let isComplete: Bool

    var coveragePercentage: Decimal {
        guard totalTokens > 0 else { return 100 }
        return Decimal(pricedTokens) * 100 / Decimal(totalTokens)
    }
}

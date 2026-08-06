import Foundation

struct CostEstimator: Sendable {
    let catalog: PricingCatalog

    func estimate(for snapshot: TokenUsageSnapshot) -> CostEstimate? {
        guard let model = snapshot.model,
              let pricing = catalog.match(model: model) else {
            return nil
        }

        let rate = pricing.rate
        let cachedRate = rate.cachedInputMicrosPerMillion ?? rate.inputMicrosPerMillion

        // 分项转换为 Decimal，避免极端 Token 数在 Int64 预相加时溢出。
        var amountMicros = Decimal(max(0, snapshot.inputTokens)) * Decimal(rate.inputMicrosPerMillion)
        amountMicros += Decimal(max(0, snapshot.cacheWriteTokens)) * Decimal(rate.inputMicrosPerMillion)
        amountMicros += Decimal(max(0, snapshot.outputTokens)) * Decimal(rate.outputMicrosPerMillion)
        amountMicros += Decimal(max(0, snapshot.reasoningTokens)) * Decimal(rate.outputMicrosPerMillion)
        amountMicros += Decimal(max(0, snapshot.cachedInputTokens)) * Decimal(cachedRate)
        amountMicros /= Decimal(1_000_000)

        var roundedAmountMicros = Decimal()
        NSDecimalRound(&roundedAmountMicros, &amountMicros, 0, .plain)
        let number = NSDecimalNumber(decimal: roundedAmountMicros)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else {
            return nil
        }

        return CostEstimate(
            amount: MoneyAmount(micros: number.int64Value, currencyCode: "USD"),
            matchedModel: pricing.canonicalModel,
            tier: pricing.tier,
            catalogVersion: pricing.catalogVersion
        )
    }

    func estimate(for snapshots: [TokenUsageSnapshot]) -> MoneyAmount? {
        guard !snapshots.isEmpty else { return nil }
        var totalMicros: Int64 = 0
        for snapshot in snapshots {
            guard let estimate = estimate(for: snapshot) else { return nil }
            let (nextValue, overflow) = totalMicros.addingReportingOverflow(estimate.amount.micros)
            guard !overflow else { return nil }
            totalMicros = nextValue
        }
        return MoneyAmount(micros: totalMicros, currencyCode: "USD")
    }

    func estimateKnown(for snapshots: [TokenUsageSnapshot]) -> CostCoverageEstimate? {
        guard !snapshots.isEmpty else { return nil }
        var totalMicros: Int64 = 0
        var pricedTokens: Int64 = 0
        var totalTokens: Int64 = 0
        var matchedCount = 0

        for snapshot in snapshots {
            let usageTokens = Self.usageTokens(for: snapshot)
            totalTokens = Self.saturatingAdd(totalTokens, usageTokens)
            guard let estimate = estimate(for: snapshot) else { continue }
            matchedCount += 1
            pricedTokens = Self.saturatingAdd(pricedTokens, usageTokens)
            totalMicros = Self.saturatingAdd(totalMicros, estimate.amount.micros)
        }

        guard matchedCount > 0 else { return nil }
        return CostCoverageEstimate(
            amount: MoneyAmount(micros: totalMicros, currencyCode: "USD"),
            pricedTokens: pricedTokens,
            totalTokens: totalTokens,
            isComplete: matchedCount == snapshots.count
        )
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }

    private static func usageTokens(for snapshot: TokenUsageSnapshot) -> Int64 {
        [
            snapshot.inputTokens,
            snapshot.cachedInputTokens,
            snapshot.cacheWriteTokens,
            snapshot.outputTokens,
            snapshot.reasoningTokens
        ].reduce(0) { saturatingAdd($0, max(0, $1)) }
    }
}

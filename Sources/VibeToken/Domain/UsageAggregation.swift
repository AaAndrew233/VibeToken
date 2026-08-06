import Foundation

struct UsageSourceBreakdown: Equatable, Sendable {
    let sourceIdentifier: String
    let displayName: String
    let modelSnapshots: [TokenUsageSnapshot]
}

struct UsageDistributionItem: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let totalTokens: Int64
    let estimatedCost: MoneyAmount?
    let isCostComplete: Bool
}

enum UsageDistributionMetric: String, CaseIterable, Identifiable, Sendable {
    case tokens
    case cost

    var id: String { rawValue }
}

struct UsageDistributionSlice: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let value: Int64
    let isCostComplete: Bool
}

enum UsageDistributionBuilder {
    static func slices(
        from items: [UsageDistributionItem],
        metric: UsageDistributionMetric,
        otherLabel: String,
        visibleItemLimit: Int = 6
    ) -> [UsageDistributionSlice] {
        guard visibleItemLimit > 0 else { return [] }
        let candidates = items.compactMap { item -> (UsageDistributionItem, Int64)? in
            switch metric {
            case .tokens:
                return item.totalTokens > 0 ? (item, item.totalTokens) : nil
            case .cost:
                guard let cost = item.estimatedCost, cost.micros > 0 else { return nil }
                return (item, cost.micros)
            }
        }.sorted { left, right in
            if left.1 == right.1 {
                return left.0.displayName.localizedStandardCompare(right.0.displayName) == .orderedAscending
            }
            return left.1 > right.1
        }

        var result = candidates.prefix(visibleItemLimit).map { item, value in
            UsageDistributionSlice(
                id: item.id,
                displayName: item.displayName,
                value: value,
                isCostComplete: item.isCostComplete
            )
        }
        let remaining = candidates.dropFirst(visibleItemLimit)
        if !remaining.isEmpty {
            result.append(UsageDistributionSlice(
                id: "other",
                displayName: otherLabel,
                value: remaining.reduce(0) { saturatingAdd($0, $1.1) },
                isCostComplete: remaining.allSatisfy { $0.0.isCostComplete }
            ))
        }
        return result
    }

    static func percentage(value: Int64, total: Int64) -> Decimal {
        guard value > 0, total > 0 else { return 0 }
        return Decimal(value) * 100 / Decimal(total)
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

struct UsageAggregation: Equatable, Sendable {
    let snapshot: TokenUsageSnapshot?
    let modelSnapshots: [TokenUsageSnapshot]
    let sourceBreakdowns: [UsageSourceBreakdown]
    let sessionCount: Int

    static let empty = UsageAggregation(
        snapshot: nil,
        modelSnapshots: [],
        sourceBreakdowns: [],
        sessionCount: 0
    )
}

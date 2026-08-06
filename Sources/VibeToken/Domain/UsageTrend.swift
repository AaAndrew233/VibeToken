import Foundation

enum UsageTrendGranularity: String, Equatable, Sendable {
    case hourly
    case daily

    static func forRange(_ range: UsageTimeRange) -> UsageTrendGranularity {
        switch range {
        case .today, .hours24:
            .hourly
        case .days7, .days30:
            .daily
        }
    }

    func intervals(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar = .current
    ) -> [UsageTrendInterval] {
        guard startDate < endDate else { return [] }
        let component: Calendar.Component = self == .hourly ? .hour : .day
        var intervals: [UsageTrendInterval] = []
        var cursor = startDate

        while cursor < endDate {
            guard let calendarInterval = calendar.dateInterval(of: component, for: cursor) else {
                break
            }
            let intervalEnd = min(calendarInterval.end, endDate)
            guard intervalEnd > cursor else { break }
            intervals.append(UsageTrendInterval(
                bucketStart: calendarInterval.start,
                rangeStart: cursor,
                rangeEnd: intervalEnd
            ))
            cursor = intervalEnd
        }
        return intervals
    }
}

struct UsageTrendInterval: Equatable, Sendable {
    let bucketStart: Date
    let rangeStart: Date
    let rangeEnd: Date
}

struct UsageTrendBucket: Equatable, Sendable {
    let bucketStart: Date
    let modelSnapshots: [TokenUsageSnapshot]
}

struct UsageTrendSeries: Equatable, Sendable {
    let granularity: UsageTrendGranularity
    let buckets: [UsageTrendBucket]

    static let empty = UsageTrendSeries(granularity: .hourly, buckets: [])
}

struct UsageTrendPoint: Equatable, Identifiable, Sendable {
    let bucketStart: Date
    let totalTokens: Int64
    let estimatedCost: MoneyAmount?
    let isCostComplete: Bool

    var id: Date { bucketStart }
}

enum UsageTrendBuilder {
    static func points(
        from series: UsageTrendSeries,
        costEstimator: CostEstimator
    ) -> [UsageTrendPoint] {
        series.buckets.map { bucket in
            let totalTokens = bucket.modelSnapshots.reduce(Int64(0)) {
                saturatingAdd($0, $1.totalTokens)
            }
            let estimates = bucket.modelSnapshots.compactMap {
                costEstimator.estimate(for: $0)?.amount
            }
            let estimatedCost = sum(estimates)
            return UsageTrendPoint(
                bucketStart: bucket.bucketStart,
                totalTokens: totalTokens,
                estimatedCost: estimatedCost,
                isCostComplete: bucket.modelSnapshots.isEmpty
                    || estimates.count == bucket.modelSnapshots.count
            )
        }
    }

    private static func sum(_ amounts: [MoneyAmount]) -> MoneyAmount? {
        guard let currencyCode = amounts.first?.currencyCode else { return nil }
        let total = amounts.reduce(Int64(0)) { partial, amount in
            guard amount.currencyCode == currencyCode else { return partial }
            return saturatingAdd(partial, amount.micros)
        }
        return MoneyAmount(micros: total, currencyCode: currencyCode)
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

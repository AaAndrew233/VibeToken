import Foundation

struct Sub2APIWindowSnapshot: Equatable, Sendable {
    let observedAccounts: Int
    let remainingEquivalentAccounts: Double
    let nextResetAt: Date?

    var remainingFraction: Double? {
        guard observedAccounts > 0 else { return nil }
        return min(1, max(0, remainingEquivalentAccounts / Double(observedAccounts)))
    }
}

struct Sub2APIPlanSnapshot: Identifiable, Equatable, Sendable {
    let plan: String
    let accountCount: Int
    let fiveHour: Sub2APIWindowSnapshot
    let sevenDay: Sub2APIWindowSnapshot

    var id: String { plan }
}

struct Sub2APIEffectiveCapacitySnapshot: Equatable, Sendable {
    let observedAccounts: Int
    let availableAccounts: Int
    let windowLimitedAccounts: Int
    let remainingEquivalentAccounts: Double
    let fiveHourRemainingEquivalentAccounts: Double
    let sevenDayRemainingEquivalentAccounts: Double
    let availableFiveHourRemainingFraction: Double?
    let availableSevenDayRemainingFraction: Double?
    let nextRecoveryAt: Date?

    var poolRemainingFraction: Double? {
        guard observedAccounts > 0 else { return nil }
        return min(1, max(0, remainingEquivalentAccounts / Double(observedAccounts)))
    }

    var availableAccountFraction: Double? {
        guard observedAccounts > 0 else { return nil }
        return Double(availableAccounts) / Double(observedAccounts)
    }

    var availableAccountRemainingFraction: Double? {
        guard availableAccounts > 0 else { return nil }
        return min(1, max(0, remainingEquivalentAccounts / Double(availableAccounts)))
    }

    var totalAvailableRemainingFraction: Double? {
        guard availableAccounts > 0 else { return nil }
        return max(0, remainingEquivalentAccounts)
    }

    var totalAvailableFiveHourRemainingFraction: Double? {
        availableFiveHourRemainingFraction.map { $0 * Double(availableAccounts) }
    }

    var totalAvailableSevenDayRemainingFraction: Double? {
        availableSevenDayRemainingFraction.map { $0 * Double(availableAccounts) }
    }
}

struct Sub2APIPoolSnapshot: Equatable, Sendable {
    let totalAccounts: Int
    let eligibleAccounts: Int
    let excludedShadowAccounts: Int
    let unavailableAccounts: Int
    let missingWindowAccounts: Int
    let staleWindowAccounts: Int
    let effectiveCapacity: Sub2APIEffectiveCapacitySnapshot
    let fiveHour: Sub2APIWindowSnapshot
    let sevenDay: Sub2APIWindowSnapshot
    let plans: [Sub2APIPlanSnapshot]
    let fetchedAt: Date

    var totalCapacityAccounts: Int {
        eligibleAccounts
    }

    var displayedAvailableAccountFraction: Double? {
        guard totalCapacityAccounts > 0 else { return nil }
        return Double(effectiveCapacity.availableAccounts) / Double(totalCapacityAccounts)
    }

    var displayedRemainingFraction: Double? {
        guard totalCapacityAccounts > 0 else { return nil }
        return min(
            1,
            max(0, effectiveCapacity.remainingEquivalentAccounts / Double(totalCapacityAccounts))
        )
    }
}

struct Sub2APIAccountSnapshot: Equatable, Sendable {
    let id: Int64
    let status: String
    let schedulable: Bool
    let parentAccountID: Int64?
    let plan: String
    let fiveHourUsedPercent: Double?
    let fiveHourResetAt: Date?
    let sevenDayUsedPercent: Double?
    let sevenDayResetAt: Date?
    let usageUpdatedAt: Date?
    let rateLimitResetAt: Date?
    let overloadUntil: Date?
    let tempUnschedulableUntil: Date?
}

enum Sub2APIPoolAggregator {
    static func aggregate(
        accounts: [Sub2APIAccountSnapshot],
        fetchedAt: Date,
        staleAfter: TimeInterval
    ) -> Sub2APIPoolSnapshot {
        let uniqueAccounts = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values
        let physicalAccounts = uniqueAccounts.filter { $0.parentAccountID == nil }
        let activeAccounts = physicalAccounts.filter { $0.status == "active" }
        let runtimeRateLimitedIDs = Set(
            activeAccounts.filter { $0.hasActiveRateLimit(at: fetchedAt) }.map(\.id)
        )
        let windowLimitedIDs = Set(
            activeAccounts.filter { account in
                if runtimeRateLimitedIDs.contains(account.id) { return true }
                return account.schedulable
                    && !account.isTemporarilyUnavailable(at: fetchedAt)
                    && account.hasExhaustedWindow
            }.map(\.id)
        )
        let eligible = activeAccounts.filter { account in
            if runtimeRateLimitedIDs.contains(account.id) { return true }
            return account.schedulable && !account.isTemporarilyUnavailable(at: fetchedAt)
        }
        let unavailable = physicalAccounts.count - eligible.count
        let staleCutoff = fetchedAt.addingTimeInterval(-staleAfter)

        let nonLimited = eligible.filter { !windowLimitedIDs.contains($0.id) }
        let missing = nonLimited.filter {
            $0.fiveHourUsedPercent == nil || $0.sevenDayUsedPercent == nil
        }
        let missingIDs = Set(missing.map(\.id))
        let stale = nonLimited.filter { account in
            guard !missingIDs.contains(account.id),
                  let updatedAt = account.usageUpdatedAt
            else {
                return false
            }
            return updatedAt < staleCutoff
        }
        let staleIDs = Set(stale.map(\.id))
        let assessable = eligible.filter {
            windowLimitedIDs.contains($0.id)
                || (!staleIDs.contains($0.id)
                    && !missingIDs.contains($0.id))
        }

        let grouped = Dictionary(grouping: eligible, by: \.plan)
        let plans = grouped.map { plan, planAccounts in
            Sub2APIPlanSnapshot(
                plan: plan,
                accountCount: planAccounts.count,
                fiveHour: summarize(planAccounts, window: .fiveHour),
                sevenDay: summarize(planAccounts, window: .sevenDay)
            )
        }
        .sorted {
            if $0.accountCount == $1.accountCount { return $0.plan < $1.plan }
            return $0.accountCount > $1.accountCount
        }

        return Sub2APIPoolSnapshot(
            totalAccounts: physicalAccounts.count,
            eligibleAccounts: eligible.count,
            excludedShadowAccounts: uniqueAccounts.count - physicalAccounts.count,
            unavailableAccounts: unavailable,
            missingWindowAccounts: missing.count,
            staleWindowAccounts: stale.count,
            effectiveCapacity: effectiveCapacity(
                assessable,
                forcedWindowLimitedIDs: windowLimitedIDs
            ),
            fiveHour: summarize(eligible, window: .fiveHour),
            sevenDay: summarize(eligible, window: .sevenDay),
            plans: plans,
            fetchedAt: fetchedAt
        )
    }

    private static func effectiveCapacity(
        _ accounts: [Sub2APIAccountSnapshot],
        forcedWindowLimitedIDs: Set<Int64>
    ) -> Sub2APIEffectiveCapacitySnapshot {
        let values = accounts.compactMap { account -> EffectiveAccountValue? in
            let forcedWindowLimited = forcedWindowLimitedIDs.contains(account.id)
            guard let fiveHourUsed = account.fiveHourUsedPercent,
                  let sevenDayUsed = account.sevenDayUsedPercent else {
                guard forcedWindowLimited else { return nil }
                return EffectiveAccountValue(
                    fiveHourRemaining: 0,
                    fiveHourResetAt: account.fiveHourResetAt,
                    sevenDayRemaining: 0,
                    sevenDayResetAt: account.sevenDayResetAt,
                    rateLimitResetAt: account.rateLimitResetAt,
                    isWindowLimited: true
                )
            }
            let fiveHourRemaining = remainingFraction(usedPercent: fiveHourUsed)
            let sevenDayRemaining = remainingFraction(usedPercent: sevenDayUsed)
            return EffectiveAccountValue(
                fiveHourRemaining: fiveHourRemaining,
                fiveHourResetAt: account.fiveHourResetAt,
                sevenDayRemaining: sevenDayRemaining,
                sevenDayResetAt: account.sevenDayResetAt,
                rateLimitResetAt: account.rateLimitResetAt,
                isWindowLimited: forcedWindowLimited
                    || fiveHourRemaining <= 0
                    || sevenDayRemaining <= 0
            )
        }
        let availableValues = values.filter { !$0.isWindowLimited }
        let windowLimitedValues = values.filter(\.isWindowLimited)
        let nextRecoveryAt = values.flatMap { value -> [Date] in
            var resetDates: [Date] = []
            if value.isWindowLimited, let resetAt = value.rateLimitResetAt {
                resetDates.append(resetAt)
            }
            if value.fiveHourRemaining <= 0, let resetAt = value.fiveHourResetAt {
                resetDates.append(resetAt)
            }
            if value.sevenDayRemaining <= 0, let resetAt = value.sevenDayResetAt {
                resetDates.append(resetAt)
            }
            return resetDates
        }.min()
        let fiveHourRemainingEquivalentAccounts = values.reduce(0) {
            $0 + $1.fiveHourRemaining
        }
        let sevenDayRemainingEquivalentAccounts = values.reduce(0) {
            $0 + $1.sevenDayRemaining
        }
        return Sub2APIEffectiveCapacitySnapshot(
            observedAccounts: values.count,
            availableAccounts: availableValues.count,
            windowLimitedAccounts: windowLimitedValues.count,
            remainingEquivalentAccounts: values.reduce(0) {
                $0 + ($1.isWindowLimited
                    ? 0
                    : min($1.fiveHourRemaining, $1.sevenDayRemaining))
            },
            fiveHourRemainingEquivalentAccounts: fiveHourRemainingEquivalentAccounts,
            sevenDayRemainingEquivalentAccounts: sevenDayRemainingEquivalentAccounts,
            availableFiveHourRemainingFraction: average(
                availableValues.map(\.fiveHourRemaining)
            ),
            availableSevenDayRemainingFraction: average(
                availableValues.map(\.sevenDayRemaining)
            ),
            nextRecoveryAt: nextRecoveryAt
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func remainingFraction(usedPercent: Double) -> Double {
        min(1, max(0, 1 - usedPercent / 100))
    }

    private enum Window {
        case fiveHour
        case sevenDay
    }

    private static func summarize(
        _ accounts: [Sub2APIAccountSnapshot],
        window: Window
    ) -> Sub2APIWindowSnapshot {
        let values: [(usedPercent: Double, resetAt: Date?)] = accounts.compactMap { account in
            switch window {
            case .fiveHour:
                account.fiveHourUsedPercent.map { ($0, account.fiveHourResetAt) }
            case .sevenDay:
                account.sevenDayUsedPercent.map { ($0, account.sevenDayResetAt) }
            }
        }
        let remaining = values.reduce(0.0) { partial, value in
            partial + remainingFraction(usedPercent: value.usedPercent)
        }
        return Sub2APIWindowSnapshot(
            observedAccounts: values.count,
            remainingEquivalentAccounts: remaining,
            nextResetAt: values.compactMap(\.resetAt).min()
        )
    }

    private struct EffectiveAccountValue {
        let fiveHourRemaining: Double
        let fiveHourResetAt: Date?
        let sevenDayRemaining: Double
        let sevenDayResetAt: Date?
        let rateLimitResetAt: Date?
        let isWindowLimited: Bool
    }
}

private extension Sub2APIAccountSnapshot {
    var hasExhaustedWindow: Bool {
        (fiveHourUsedPercent.map { $0 >= 100 } ?? false)
            || (sevenDayUsedPercent.map { $0 >= 100 } ?? false)
    }

    func hasActiveRateLimit(at date: Date) -> Bool {
        rateLimitResetAt.map { $0 > date } ?? false
    }

    func isTemporarilyUnavailable(at date: Date) -> Bool {
        (overloadUntil.map { $0 > date } ?? false)
            || (tempUnschedulableUntil.map { $0 > date } ?? false)
    }
}

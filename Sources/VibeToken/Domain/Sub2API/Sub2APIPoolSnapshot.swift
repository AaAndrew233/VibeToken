import Foundation

struct Sub2APIWindowSnapshot: Equatable, Sendable {
    let observedAccounts: Int
    let remainingEquivalentAccounts: Double
    let totalCapacityWeight: Double
    let nextResetAt: Date?

    init(
        observedAccounts: Int,
        remainingEquivalentAccounts: Double,
        totalCapacityWeight: Double? = nil,
        nextResetAt: Date?
    ) {
        self.observedAccounts = observedAccounts
        self.remainingEquivalentAccounts = remainingEquivalentAccounts
        self.totalCapacityWeight = totalCapacityWeight ?? Double(observedAccounts)
        self.nextResetAt = nextResetAt
    }

    var remainingFraction: Double? {
        guard totalCapacityWeight > 0 else { return nil }
        return min(1, max(0, remainingEquivalentAccounts / totalCapacityWeight))
    }
}

struct Sub2APIPlanSnapshot: Identifiable, Equatable, Sendable {
    let plan: String
    let accountCount: Int
    let availableAccountCount: Int
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
    let totalCapacityWeight: Double
    let availableCapacityWeight: Double

    init(
        observedAccounts: Int,
        availableAccounts: Int,
        windowLimitedAccounts: Int,
        remainingEquivalentAccounts: Double,
        fiveHourRemainingEquivalentAccounts: Double,
        sevenDayRemainingEquivalentAccounts: Double,
        availableFiveHourRemainingFraction: Double?,
        availableSevenDayRemainingFraction: Double?,
        nextRecoveryAt: Date?,
        totalCapacityWeight: Double? = nil,
        availableCapacityWeight: Double? = nil
    ) {
        self.observedAccounts = observedAccounts
        self.availableAccounts = availableAccounts
        self.windowLimitedAccounts = windowLimitedAccounts
        self.remainingEquivalentAccounts = remainingEquivalentAccounts
        self.fiveHourRemainingEquivalentAccounts = fiveHourRemainingEquivalentAccounts
        self.sevenDayRemainingEquivalentAccounts = sevenDayRemainingEquivalentAccounts
        self.availableFiveHourRemainingFraction = availableFiveHourRemainingFraction
        self.availableSevenDayRemainingFraction = availableSevenDayRemainingFraction
        self.nextRecoveryAt = nextRecoveryAt
        self.totalCapacityWeight = totalCapacityWeight ?? Double(observedAccounts)
        self.availableCapacityWeight = availableCapacityWeight ?? Double(availableAccounts)
    }

    var poolRemainingFraction: Double? {
        guard totalCapacityWeight > 0 else { return nil }
        return min(1, max(0, remainingEquivalentAccounts / totalCapacityWeight))
    }

    var availableAccountFraction: Double? {
        guard observedAccounts > 0 else { return nil }
        return Double(availableAccounts) / Double(observedAccounts)
    }

    var availableAccountRemainingFraction: Double? {
        guard availableCapacityWeight > 0 else { return nil }
        return min(1, max(0, remainingEquivalentAccounts / availableCapacityWeight))
    }

    var totalAvailableRemainingFraction: Double? {
        guard availableAccounts > 0 else { return nil }
        return max(0, remainingEquivalentAccounts)
    }

    var totalAvailableFiveHourRemainingFraction: Double? {
        availableFiveHourRemainingFraction.map { $0 * availableCapacityWeight }
    }

    var totalAvailableSevenDayRemainingFraction: Double? {
        availableSevenDayRemainingFraction.map { $0 * availableCapacityWeight }
    }
}

struct Sub2APIPoolSnapshot: Equatable, Sendable {
    let totalAccounts: Int
    let eligibleAccounts: Int
    let excludedShadowAccounts: Int
    let unavailableAccounts: Int
    let missingWindowAccounts: Int
    let staleWindowAccounts: Int
    let unconfiguredCapacityAccounts: Int
    let effectiveCapacity: Sub2APIEffectiveCapacitySnapshot
    let fiveHour: Sub2APIWindowSnapshot
    let sevenDay: Sub2APIWindowSnapshot
    let plans: [Sub2APIPlanSnapshot]
    let fetchedAt: Date

    var totalCapacityAccounts: Int {
        effectiveCapacity.observedAccounts
    }

    var totalCapacityWeight: Double {
        effectiveCapacity.totalCapacityWeight
    }

    var displayedAvailableAccountFraction: Double? {
        guard totalCapacityAccounts > 0 else { return nil }
        return Double(effectiveCapacity.availableAccounts) / Double(totalCapacityAccounts)
    }

    var displayedRemainingFraction: Double? {
        guard unconfiguredCapacityAccounts == 0 else { return nil }
        return effectiveCapacity.poolRemainingFraction
    }

    var requiresCapacityConfiguration: Bool {
        unconfiguredCapacityAccounts > 0
    }
}

struct Sub2APIAccountSnapshot: Equatable, Sendable {
    let id: Int64
    let status: String
    let schedulable: Bool
    let parentAccountID: Int64?
    let plan: String
    let capacityTier: Sub2APICapacityTier?
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
        let unconfiguredCapacityAccounts = activeAccounts.filter {
            $0.capacityTier == nil
        }.count
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
        let operational = activeAccounts.filter { account in
            if runtimeRateLimitedIDs.contains(account.id) { return true }
            return account.schedulable && !account.isTemporarilyUnavailable(at: fetchedAt)
        }
        let operationalIDs = Set(operational.map(\.id))
        let unavailable = physicalAccounts.count - operational.count
        let staleCutoff = fetchedAt.addingTimeInterval(-staleAfter)

        let nonLimited = operational.filter { !windowLimitedIDs.contains($0.id) }
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
        let unavailableCapacityIDs = Set(activeAccounts.map(\.id)).subtracting(operationalIDs)
        let zeroContributionIDs = windowLimitedIDs
            .union(unavailableCapacityIDs)
            .union(staleIDs)
            .union(missingIDs)

        let grouped = Dictionary(grouping: activeAccounts, by: \.plan)
        let plans = grouped.map { plan, planAccounts in
            Sub2APIPlanSnapshot(
                plan: plan,
                accountCount: planAccounts.count,
                availableAccountCount: planAccounts.count {
                    !zeroContributionIDs.contains($0.id)
                },
                fiveHour: summarize(
                    planAccounts,
                    window: .fiveHour,
                    zeroContributionIDs: zeroContributionIDs,
                    fetchedAt: fetchedAt
                ),
                sevenDay: summarize(
                    planAccounts,
                    window: .sevenDay,
                    zeroContributionIDs: zeroContributionIDs,
                    fetchedAt: fetchedAt
                )
            )
        }
        .sorted {
            if $0.accountCount == $1.accountCount { return $0.plan < $1.plan }
            return $0.accountCount > $1.accountCount
        }

        return Sub2APIPoolSnapshot(
            totalAccounts: physicalAccounts.count,
            eligibleAccounts: operational.count,
            excludedShadowAccounts: uniqueAccounts.count - physicalAccounts.count,
            unavailableAccounts: unavailable,
            missingWindowAccounts: missing.count,
            staleWindowAccounts: stale.count,
            unconfiguredCapacityAccounts: unconfiguredCapacityAccounts,
            effectiveCapacity: effectiveCapacity(
                activeAccounts,
                zeroContributionIDs: zeroContributionIDs,
                windowLimitedIDs: windowLimitedIDs,
                fetchedAt: fetchedAt
            ),
            fiveHour: summarize(
                activeAccounts,
                window: .fiveHour,
                zeroContributionIDs: zeroContributionIDs,
                fetchedAt: fetchedAt
            ),
            sevenDay: summarize(
                activeAccounts,
                window: .sevenDay,
                zeroContributionIDs: zeroContributionIDs,
                fetchedAt: fetchedAt
            ),
            plans: plans,
            fetchedAt: fetchedAt
        )
    }

    private static func effectiveCapacity(
        _ accounts: [Sub2APIAccountSnapshot],
        zeroContributionIDs: Set<Int64>,
        windowLimitedIDs: Set<Int64>,
        fetchedAt: Date
    ) -> Sub2APIEffectiveCapacitySnapshot {
        let values = accounts.compactMap { account -> EffectiveAccountValue? in
            let isUnavailable = zeroContributionIDs.contains(account.id)
            let isWindowLimited = windowLimitedIDs.contains(account.id)
            let recoveryAt = isWindowLimited
                ? account.estimatedRecoveryAt(after: fetchedAt)
                : nil
            guard let fiveHourUsed = account.fiveHourUsedPercent,
                  let sevenDayUsed = account.sevenDayUsedPercent else {
                return EffectiveAccountValue(
                    fiveHourRemaining: 0,
                    sevenDayRemaining: 0,
                    recoveryAt: recoveryAt,
                    isWindowLimited: isWindowLimited,
                    isAvailable: false,
                    capacityWeight: account.capacityTier?.multiplier ?? 0
                )
            }
            let fiveHourRemaining = isUnavailable
                ? 0
                : remainingFraction(usedPercent: fiveHourUsed)
            let sevenDayRemaining = isUnavailable
                ? 0
                : remainingFraction(usedPercent: sevenDayUsed)
            return EffectiveAccountValue(
                fiveHourRemaining: fiveHourRemaining,
                sevenDayRemaining: sevenDayRemaining,
                recoveryAt: recoveryAt,
                isWindowLimited: isWindowLimited,
                isAvailable: !isUnavailable,
                capacityWeight: account.capacityTier?.multiplier ?? 0
            )
        }
        let availableValues = values.filter(\.isAvailable)
        let windowLimitedValues = values.filter(\.isWindowLimited)
        let nextRecoveryAt = windowLimitedValues.compactMap(\.recoveryAt).min()
        let fiveHourRemainingEquivalentAccounts = values.reduce(0) {
            $0 + $1.fiveHourRemaining * $1.capacityWeight
        }
        let sevenDayRemainingEquivalentAccounts = values.reduce(0) {
            $0 + $1.sevenDayRemaining * $1.capacityWeight
        }
        let totalCapacityWeight = values.reduce(0) { $0 + $1.capacityWeight }
        let availableCapacityWeight = availableValues.reduce(0) { $0 + $1.capacityWeight }
        return Sub2APIEffectiveCapacitySnapshot(
            observedAccounts: values.count,
            availableAccounts: availableValues.count,
            windowLimitedAccounts: windowLimitedValues.count,
            remainingEquivalentAccounts: values.reduce(0) {
                $0 + min($1.fiveHourRemaining, $1.sevenDayRemaining) * $1.capacityWeight
            },
            fiveHourRemainingEquivalentAccounts: fiveHourRemainingEquivalentAccounts,
            sevenDayRemainingEquivalentAccounts: sevenDayRemainingEquivalentAccounts,
            availableFiveHourRemainingFraction: average(
                availableValues.map { ($0.fiveHourRemaining, $0.capacityWeight) }
            ),
            availableSevenDayRemainingFraction: average(
                availableValues.map { ($0.sevenDayRemaining, $0.capacityWeight) }
            ),
            nextRecoveryAt: nextRecoveryAt,
            totalCapacityWeight: totalCapacityWeight,
            availableCapacityWeight: availableCapacityWeight
        )
    }

    private static func average(_ values: [(value: Double, weight: Double)]) -> Double? {
        guard !values.isEmpty else { return nil }
        let totalWeight = values.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        return values.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
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
        window: Window,
        zeroContributionIDs: Set<Int64>,
        fetchedAt: Date
    ) -> Sub2APIWindowSnapshot {
        let values: [(remaining: Double, resetAt: Date?, weight: Double)] = accounts.map { account in
            let remaining: Double
            let resetAt: Date?
            switch window {
            case .fiveHour:
                remaining = account.fiveHourUsedPercent.map {
                    remainingFraction(usedPercent: $0)
                } ?? 0
                resetAt = account.fiveHourResetAt
            case .sevenDay:
                remaining = account.sevenDayUsedPercent.map {
                    remainingFraction(usedPercent: $0)
                } ?? 0
                resetAt = account.sevenDayResetAt
            }
            return (
                zeroContributionIDs.contains(account.id) ? 0 : remaining,
                resetAt,
                account.capacityTier?.multiplier ?? 0
            )
        }
        let remaining = values.reduce(0.0) { partial, value in
            partial + value.remaining * value.weight
        }
        return Sub2APIWindowSnapshot(
            observedAccounts: values.count,
            remainingEquivalentAccounts: remaining,
            totalCapacityWeight: values.reduce(0) { $0 + $1.weight },
            nextResetAt: values.compactMap(\.resetAt).filter { $0 > fetchedAt }.min()
        )
    }

    private struct EffectiveAccountValue {
        let fiveHourRemaining: Double
        let sevenDayRemaining: Double
        let recoveryAt: Date?
        let isWindowLimited: Bool
        let isAvailable: Bool
        let capacityWeight: Double
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

    func estimatedRecoveryAt(after date: Date) -> Date? {
        var blockers: [Date] = []

        if fiveHourUsedPercent.map({ $0 >= 100 }) == true {
            guard let fiveHourResetAt, fiveHourResetAt > date else { return nil }
            blockers.append(fiveHourResetAt)
        }
        if sevenDayUsedPercent.map({ $0 >= 100 }) == true {
            guard let sevenDayResetAt, sevenDayResetAt > date else { return nil }
            blockers.append(sevenDayResetAt)
        }
        if let rateLimitResetAt, rateLimitResetAt > date {
            blockers.append(rateLimitResetAt)
        }

        return blockers.max()
    }

    func isTemporarilyUnavailable(at date: Date) -> Bool {
        (overloadUntil.map { $0 > date } ?? false)
            || (tempUnschedulableUntil.map { $0 > date } ?? false)
    }
}

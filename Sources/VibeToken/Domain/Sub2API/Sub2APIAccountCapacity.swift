import Foundation

enum Sub2APICapacityTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case plus
    case pro5
    case pro10
    case pro20

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .plus: 1
        case .pro5: 5
        case .pro10: 10
        case .pro20: 20
        }
    }

    var displayName: String {
        switch self {
        case .plus: "Plus"
        case .pro5: "Pro 5x"
        case .pro10: "Pro 10x"
        case .pro20: "Pro 20x"
        }
    }

    var isProCapacity: Bool {
        self != .plus
    }
}

struct Sub2APIAccountCapacitySelection: Codable, Equatable, Sendable {
    let accountID: Int64
    let tier: Sub2APICapacityTier
}

struct Sub2APIAccountCapacityConfiguration: Codable, Equatable, Sendable {
    let selectionsByServer: [String: [Sub2APIAccountCapacitySelection]]

    static let empty = Sub2APIAccountCapacityConfiguration(selectionsByServer: [:])

    func tiersByAccountID(serverIdentifier: String) -> [Int64: Sub2APICapacityTier] {
        Dictionary(
            (selectionsByServer[serverIdentifier] ?? []).map { ($0.accountID, $0.tier) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func updating(
        serverIdentifier: String,
        tiersByAccountID: [Int64: Sub2APICapacityTier]
    ) -> Sub2APIAccountCapacityConfiguration {
        var updated = selectionsByServer
        updated[serverIdentifier] = tiersByAccountID
            .map { Sub2APIAccountCapacitySelection(accountID: $0.key, tier: $0.value) }
            .sorted { $0.accountID < $1.accountID }
        return Sub2APIAccountCapacityConfiguration(selectionsByServer: updated)
    }
}

struct Sub2APIAccountCapacityOption: Identifiable, Equatable, Sendable {
    let accountID: Int64
    let displayName: String?
    let detectedPlan: String
    let selectedTier: Sub2APICapacityTier?
    let subscriptionExpiresAt: Date?
    let runtimeStatus: Sub2APIAccountRuntimeStatus
    let quotaStatus: Sub2APIAccountQuotaStatus
    let nextRecoveryAt: Date?

    var id: Int64 { accountID }

    var displayedRecoveryAt: Date? {
        runtimeStatus == .rateLimited ? nextRecoveryAt : nil
    }

    var isAvailableForDisplay: Bool {
        guard runtimeStatus == .available else { return false }
        guard case .current(let fiveHourRemaining, let sevenDayRemaining) = quotaStatus else {
            return false
        }
        return fiveHourRemaining > 0 && sevenDayRemaining > 0
    }

    var isInvalidForSorting: Bool {
        if runtimeStatus == .unavailable { return true }
        if case .current = quotaStatus { return false }
        return true
    }

    static func sorted(_ options: [Self]) -> [Self] {
        options.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isInvalidForSorting != rhs.element.isInvalidForSorting {
                    return !lhs.element.isInvalidForSorting
                }

                let lhsIsPro = lhs.element.detectedPlan.caseInsensitiveCompare("Pro") == .orderedSame
                let rhsIsPro = rhs.element.detectedPlan.caseInsensitiveCompare("Pro") == .orderedSame
                if lhsIsPro != rhsIsPro { return lhsIsPro }

                switch (lhs.element.nextRecoveryAt, rhs.element.nextRecoveryAt) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}

enum Sub2APIAccountRuntimeStatus: Equatable, Sendable {
    case available
    case rateLimited
    case unavailable

    init(
        status: String,
        schedulable: Bool,
        rateLimitResetAt: Date?,
        overloadUntil: Date?,
        tempUnschedulableUntil: Date?,
        observedAt: Date
    ) {
        guard status.caseInsensitiveCompare("active") == .orderedSame else {
            self = .unavailable
            return
        }

        if rateLimitResetAt.map({ $0 > observedAt }) == true {
            self = .rateLimited
            return
        }

        if !schedulable
            || overloadUntil.map({ $0 > observedAt }) == true
            || tempUnschedulableUntil.map({ $0 > observedAt }) == true {
            self = .unavailable
            return
        }

        self = .available
    }
}

enum Sub2APIAccountQuotaStatus: Equatable, Sendable {
    case current(fiveHourRemainingPercent: Double, sevenDayRemainingPercent: Double)
    case stale
    case unobserved

    init(
        fiveHourUsedPercent: Double?,
        sevenDayUsedPercent: Double?,
        usageUpdatedAt: Date?,
        observedAt: Date,
        staleAfter: TimeInterval,
        explicitlyLimited: Bool
    ) {
        if explicitlyLimited,
           fiveHourUsedPercent == nil || sevenDayUsedPercent == nil {
            self = .current(fiveHourRemainingPercent: 0, sevenDayRemainingPercent: 0)
            return
        }

        if let usageUpdatedAt,
           usageUpdatedAt < observedAt.addingTimeInterval(-max(0, staleAfter)) {
            self = .stale
            return
        }

        guard let fiveHourRemainingPercent = Self.remainingPercent(
            usedPercent: fiveHourUsedPercent
        ), let sevenDayRemainingPercent = Self.remainingPercent(
            usedPercent: sevenDayUsedPercent
        ) else {
            self = .unobserved
            return
        }

        self = .current(
            fiveHourRemainingPercent: fiveHourRemainingPercent,
            sevenDayRemainingPercent: sevenDayRemainingPercent
        )
    }

    private static func remainingPercent(usedPercent: Double?) -> Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return 100 - min(100, max(0, usedPercent))
    }
}

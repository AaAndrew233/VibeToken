import Foundation

// 套餐月费不代表相对 Plus 的额度倍数，不能用于容量加权。
enum Sub2APIProPlan: String, Codable, CaseIterable, Identifiable, Sendable {
    case pro100
    case pro200
    case pro500

    var id: String { rawValue }

    init?(upstreamValue: String?) {
        let key = (upstreamValue ?? "").lowercased().filter {
            !$0.isWhitespace && $0 != "_" && $0 != "-"
        }
        switch key {
        case "prolite": self = .pro100
        case "pro", "chatgptpro": self = .pro200
        case "promax": self = .pro500
        default: return nil
        }
    }

    var canonicalPlanType: String {
        switch self {
        case .pro100: "Prolite"
        case .pro200: "Pro"
        case .pro500: "Promax"
        }
    }

    var displayName: String {
        switch self {
        case .pro100: "Pro $100"
        case .pro200: "Pro $200"
        case .pro500: "Pro $500"
        }
    }
}

enum Sub2APICapacityTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case plus
    case pro5
    case pro10
    case pro20
    case excluded

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .plus: 1
        case .pro5: 5
        case .pro10: 10
        case .pro20: 20
        case .excluded: 0
        }
    }

    var displayName: String {
        switch self {
        case .plus: "Plus"
        case .pro5: "Pro 5x"
        case .pro10: "Pro 10x"
        case .pro20: "Pro 20x"
        case .excluded: "Excluded"
        }
    }

    var isProCapacity: Bool {
        self == .pro5 || self == .pro10 || self == .pro20
    }
}

struct Sub2APIAccountCapacitySelection: Codable, Equatable, Sendable {
    let accountID: Int64
    let tier: Sub2APICapacityTier?
    var proPlan: Sub2APIProPlan? = nil
}

struct Sub2APIAccountCapacityConfiguration: Codable, Equatable, Sendable {
    let selectionsByServer: [String: [Sub2APIAccountCapacitySelection]]

    static let empty = Sub2APIAccountCapacityConfiguration(selectionsByServer: [:])

    func tiersByAccountID(serverIdentifier: String) -> [Int64: Sub2APICapacityTier] {
        Dictionary(
            (selectionsByServer[serverIdentifier] ?? []).compactMap { selection in
                selection.tier.map { (selection.accountID, $0) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func proPlansByAccountID(serverIdentifier: String) -> [Int64: Sub2APIProPlan] {
        Dictionary(
            (selectionsByServer[serverIdentifier] ?? []).compactMap { selection in
                selection.proPlan.map { (selection.accountID, $0) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func updating(
        serverIdentifier: String,
        tiersByAccountID: [Int64: Sub2APICapacityTier],
        proPlansByAccountID: [Int64: Sub2APIProPlan]? = nil
    ) -> Sub2APIAccountCapacityConfiguration {
        var updated = selectionsByServer
        let plans = proPlansByAccountID ?? self.proPlansByAccountID(serverIdentifier: serverIdentifier)
        updated[serverIdentifier] = Set(tiersByAccountID.keys).union(plans.keys)
            .map {
                Sub2APIAccountCapacitySelection(
                    accountID: $0, tier: tiersByAccountID[$0], proPlan: plans[$0]
                )
            }
            .sorted { $0.accountID < $1.accountID }
        return Sub2APIAccountCapacityConfiguration(selectionsByServer: updated)
    }
}

struct Sub2APIAccountCapacityOption: Identifiable, Equatable, Sendable {
    let accountID: Int64
    let displayName: String?
    let detectedPlan: String
    let selectedTier: Sub2APICapacityTier?
    let runtimeStatus: Sub2APIAccountRuntimeStatus
    let quotaStatus: Sub2APIAccountQuotaStatus
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let nextRecoveryAt: Date?
    var unavailableReason: Sub2APIAccountUnavailableReason? = nil
    var proPlan: Sub2APIProPlan? = nil

    var id: Int64 { accountID }

    var isPro: Bool {
        Sub2APIProPlan(upstreamValue: detectedPlan) != nil
    }

    var quotaPresentation: Sub2APIAccountQuotaPresentation {
        Sub2APIAccountQuotaPresentation(
            status: quotaStatus,
            fiveHourResetAt: fiveHourResetAt,
            sevenDayResetAt: sevenDayResetAt
        )
    }

    var isAvailableForDisplay: Bool {
        guard runtimeStatus == .available else { return false }
        return !quotaStatus.isExhausted
    }

    var isInvalidForSorting: Bool {
        runtimeStatus == .unavailable
    }

    static func sorted(_ options: [Self]) -> [Self] {
        options.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isInvalidForSorting != rhs.element.isInvalidForSorting {
                    return !lhs.element.isInvalidForSorting
                }

                let lhsIsPro = lhs.element.isPro
                let rhsIsPro = rhs.element.isPro
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

enum Sub2APIAccountQuotaPresentation: Equatable, Sendable {
    case weekly(sevenDayRemainingPercent: Double, sevenDayResetAt: Date?)
    case current(
        fiveHourRemainingPercent: Double,
        sevenDayRemainingPercent: Double,
        fiveHourResetAt: Date?,
        sevenDayResetAt: Date?
    )
    case stale
    case unobserved

    init(
        status: Sub2APIAccountQuotaStatus,
        fiveHourResetAt: Date?,
        sevenDayResetAt: Date?
    ) {
        switch status {
        case .weekly(let remaining):
            self = .weekly(sevenDayRemainingPercent: remaining, sevenDayResetAt: sevenDayResetAt)
        case .current(let fiveHourRemainingPercent, let sevenDayRemainingPercent):
            self = .current(
                fiveHourRemainingPercent: fiveHourRemainingPercent,
                sevenDayRemainingPercent: sevenDayRemainingPercent,
                fiveHourResetAt: fiveHourResetAt,
                sevenDayResetAt: sevenDayResetAt
            )
        case .stale, .exhaustedWithIncompleteData:
            self = .stale
        case .unobserved:
            self = .unobserved
        }
    }

    var showsResetTimes: Bool {
        if case .current = self { return true }
        if case .weekly = self { return true }
        return false
    }
}

enum Sub2APIQuotaResetFormatter {
    static func string(
        from date: Date?,
        language: AppLanguage,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = language == .simplifiedChinese
            ? Locale(identifier: "zh_Hans_CN")
            : Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
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

enum Sub2APIAccountUnavailableReason: Equatable, Sendable {
    case inactive
    case paused
    case overloaded
    case coolingDown

    var localizationKey: CopyKey {
        switch self {
        case .inactive: .accountInactive
        case .paused: .accountPaused
        case .overloaded: .accountOverloaded
        case .coolingDown: .accountCoolingDown
        }
    }
}

enum Sub2APIAccountQuotaStatus: Equatable, Sendable {
    case current(fiveHourRemainingPercent: Double, sevenDayRemainingPercent: Double)
    case weekly(sevenDayRemainingPercent: Double)
    case exhaustedWithIncompleteData
    case stale
    case unobserved

    var isExhausted: Bool {
        if case .exhaustedWithIncompleteData = self { return true }
        if case .weekly(let remaining) = self { return remaining <= 0 }
        guard case .current(let fiveHourRemaining, let sevenDayRemaining) = self else {
            return false
        }
        return fiveHourRemaining <= 0 || sevenDayRemaining <= 0
    }

    init(
        fiveHourUsedPercent: Double?,
        sevenDayUsedPercent: Double?,
        usageUpdatedAt: Date?,
        observedAt: Date,
        staleAfter: TimeInterval,
        explicitlyLimited: Bool,
        fiveHourResetAt: Date? = nil,
        sevenDayResetAt: Date? = nil,
        requiresFiveHourWindow: Bool = true
    ) {
        if explicitlyLimited,
           (requiresFiveHourWindow && fiveHourUsedPercent == nil) || sevenDayUsedPercent == nil {
            self = requiresFiveHourWindow
                ? .current(fiveHourRemainingPercent: 0, sevenDayRemainingPercent: 0)
                : .weekly(sevenDayRemainingPercent: 0)
            return
        }

        guard let usageUpdatedAt else {
            self = .unobserved
            return
        }
        if usageUpdatedAt < observedAt.addingTimeInterval(-max(0, staleAfter)) {
            self = .stale
            return
        }

        // 已过重置时间的耗尽记录只能等待刷新，不能继续证明账号受限。
        let fiveHourExpired = fiveHourUsedPercent.map { $0 >= 100 } == true
            && fiveHourResetAt.map { $0 <= observedAt } == true
        let sevenDayExpired = sevenDayUsedPercent.map { $0 >= 100 } == true
            && sevenDayResetAt.map { $0 <= observedAt } == true
        let hasConfirmedExhaustion = (fiveHourUsedPercent.map { $0.isFinite && $0 >= 100 } == true
            && !fiveHourExpired)
            || (sevenDayUsedPercent.map { $0.isFinite && $0 >= 100 } == true && !sevenDayExpired)
        if fiveHourExpired || sevenDayExpired {
            self = hasConfirmedExhaustion ? .exhaustedWithIncompleteData : .stale
            return
        }

        if !requiresFiveHourWindow,
           let remaining = Self.remainingPercent(usedPercent: sevenDayUsedPercent) {
            self = .weekly(sevenDayRemainingPercent: remaining)
            return
        }

        guard let fiveHourRemainingPercent = Self.remainingPercent(
            usedPercent: fiveHourUsedPercent
        ), let sevenDayRemainingPercent = Self.remainingPercent(
            usedPercent: sevenDayUsedPercent
        ) else {
            self = hasConfirmedExhaustion ? .exhaustedWithIncompleteData : .unobserved
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

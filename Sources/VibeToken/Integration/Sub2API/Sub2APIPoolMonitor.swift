import Foundation

actor Sub2APIPoolMonitor {
    private let client: any Sub2APIClientServing
    private let sessionStore: any Sub2APISessionStoring
    private let connectionStore: any Sub2APIConnectionStoring
    private let capacityConfigurationStore: any Sub2APICapacityConfigurationStoring
    private let pageSize: Int
    private let maximumPages: Int
    private let staleAfter: TimeInterval
    private let minimumRefreshInterval: TimeInterval
    private let usageRefreshInterval: TimeInterval
    private let usageReadbackAttempts: Int
    private let usageReadbackDelay: Duration

    private var cachedSnapshot: Sub2APIPoolSnapshot?
    private var cachedAccountPayloads: [Sub2APIAccountPayload] = []
    private var cachedConnection: Sub2APIConnection?
    private var lastUsageRefreshAt: Date?
    private var lastSuccessfulUsageRefreshAt: Date?
    private var supportsUsageRefresh = true
    private var hasLoadedSavedConnection = false
    private var pendingTwoFactor: (connection: Sub2APIConnection, tempToken: String)?

    init(
        client: any Sub2APIClientServing,
        sessionStore: any Sub2APISessionStoring,
        connectionStore: any Sub2APIConnectionStoring,
        capacityConfigurationStore: any Sub2APICapacityConfigurationStoring,
        pageSize: Int,
        maximumPages: Int,
        staleAfter: TimeInterval,
        minimumRefreshInterval: TimeInterval,
        usageRefreshInterval: TimeInterval,
        usageReadbackAttempts: Int = 9,
        usageReadbackDelay: Duration = .seconds(1)
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.connectionStore = connectionStore
        self.capacityConfigurationStore = capacityConfigurationStore
        self.pageSize = pageSize
        self.maximumPages = maximumPages
        self.staleAfter = staleAfter
        self.minimumRefreshInterval = minimumRefreshInterval
        self.usageRefreshInterval = usageRefreshInterval
        self.usageReadbackAttempts = max(1, usageReadbackAttempts)
        self.usageReadbackDelay = usageReadbackDelay
    }

    func savedConnection() -> Sub2APIConnection? {
        if hasLoadedSavedConnection { return cachedConnection }
        hasLoadedSavedConnection = true
        guard let connection = try? connectionStore.load(),
              let _ = try? sessionStore.load()
        else {
            cachedConnection = nil
            return nil
        }
        cachedConnection = connection
        return connection
    }

    func login(serverURL: String, email: String, password: String) async throws -> Sub2APILoginResult {
        let baseURL = try Sub2APIURLBuilder.normalize(serverURL)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            throw Sub2APIError.invalidCredentials
        }
        let connection = Sub2APIConnection(baseURL: baseURL, email: normalizedEmail)
        let result = try await client.login(baseURL: baseURL, email: normalizedEmail, password: password)
        switch result {
        case .authenticated:
            do {
                try connectionStore.save(connection)
            } catch {
                try? sessionStore.delete()
                throw error
            }
            cachedConnection = connection
            hasLoadedSavedConnection = true
            pendingTwoFactor = nil
        case .requiresTwoFactor(let tempToken, _):
            pendingTwoFactor = (connection, tempToken)
        }
        return result
    }

    func completeTwoFactor(code: String) async throws {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCode.count == 6,
              normalizedCode.allSatisfy(\.isNumber),
              let pendingTwoFactor
        else {
            throw Sub2APIError.twoFactorExpired
        }
        _ = try await client.completeTwoFactor(
            baseURL: pendingTwoFactor.connection.baseURL,
            tempToken: pendingTwoFactor.tempToken,
            code: normalizedCode
        )
        do {
            try connectionStore.save(pendingTwoFactor.connection)
        } catch {
            try? sessionStore.delete()
            throw error
        }
        cachedConnection = pendingTwoFactor.connection
        hasLoadedSavedConnection = true
        self.pendingTwoFactor = nil
    }

    func refresh(force: Bool) async throws -> Sub2APIPoolSnapshot? {
        guard let connection = savedConnection() else { return nil }
        if !force,
           let cachedSnapshot,
           Date().timeIntervalSince(cachedSnapshot.fetchedAt) < minimumRefreshInterval {
            return cachedSnapshot
        }

        let fetchedAt = Date()
        var payloads = try await client.fetchAccounts(
            baseURL: connection.baseURL,
            pageSize: pageSize,
            maximumPages: maximumPages
        )
        let usageAccountIDs = activePhysicalAccountIDs(in: payloads)
        let accountSetChanged = cachedSnapshot != nil
            && usageAccountIDs != activePhysicalAccountIDs(in: cachedAccountPayloads)
        if force {
            supportsUsageRefresh = true
        }
        guard supportsUsageRefresh || usageAccountIDs.isEmpty else {
            throw Sub2APIError.incompatibleServer
        }
        if (force || accountSetChanged || shouldRefreshUsage(at: fetchedAt)), !usageAccountIDs.isEmpty {
            lastUsageRefreshAt = fetchedAt
            do {
                payloads = try await refreshAndVerifyUsage(
                    baseURL: connection.baseURL,
                    baselinePayloads: payloads,
                    startedAt: fetchedAt
                )
                lastSuccessfulUsageRefreshAt = Date()
            } catch Sub2APIError.incompatibleServer {
                supportsUsageRefresh = false
                throw Sub2APIError.incompatibleServer
            }
        }
        cachedAccountPayloads = payloads
        let snapshot = try aggregateCachedAccounts(fetchedAt: fetchedAt)
        cachedSnapshot = snapshot
        return snapshot
    }

    func lastSuccessfulUsageRefreshDate() -> Date? {
        lastSuccessfulUsageRefreshAt
    }

    func capacityOptions() throws -> [Sub2APIAccountCapacityOption] {
        let tiers = try savedTiers()
        let observedAt = Date()
        let payloads = physicalAccountPayloads()
        let prioritizedPayloads = payloads.filter(\.requiresManualCapacityTier)
            + payloads.filter { !$0.requiresManualCapacityTier }
        return prioritizedPayloads.map { payload in
            let selectedTier = payload.resolvedCapacityTier(
                configuredTier: tiers[payload.id]
            )
            let snapshot = payload.snapshot(
                now: observedAt,
                capacityTier: selectedTier
            )
            return Sub2APIAccountCapacityOption(
                accountID: payload.id,
                displayName: payload.capacityDisplayName,
                detectedPlan: payload.detectedPlan,
                selectedTier: selectedTier,
                quotaStatus: Sub2APIAccountQuotaStatus(
                    fiveHourUsedPercent: snapshot.fiveHourUsedPercent,
                    sevenDayUsedPercent: snapshot.sevenDayUsedPercent,
                    usageUpdatedAt: snapshot.usageUpdatedAt,
                    observedAt: observedAt,
                    staleAfter: staleAfter,
                    explicitlyLimited: snapshot.hasExplicitZeroCapacityState(at: observedAt)
                )
            )
        }
    }

    func saveCapacitySelections(
        _ selections: [Sub2APIAccountCapacitySelection]
    ) throws -> Sub2APIPoolSnapshot? {
        let visibleAccountIDs = Set(physicalAccountPayloads().map(\.id))
        let submitted = Dictionary(
            selections
                .filter { visibleAccountIDs.contains($0.accountID) }
                .map { ($0.accountID, $0.tier) },
            uniquingKeysWith: { _, latest in latest }
        )
        guard let serverIdentifier = cachedConnection?.baseURL.absoluteString else {
            throw Sub2APIError.secureStorageFailed
        }
        let savedConfiguration = try capacityConfigurationStore.load() ?? .empty
        var merged = savedConfiguration.tiersByAccountID(serverIdentifier: serverIdentifier)
        for payload in physicalAccountPayloads() {
            if payload.requiresManualCapacityTier {
                guard let tier = submitted[payload.id], tier.isProCapacity else {
                    throw Sub2APIError.capacityConfigurationIncomplete
                }
                merged[payload.id] = tier
            } else {
                merged[payload.id] = .plus
            }
        }
        let configuration = savedConfiguration.updating(
            serverIdentifier: serverIdentifier,
            tiersByAccountID: merged
        )
        try capacityConfigurationStore.save(configuration)

        guard let fetchedAt = cachedSnapshot?.fetchedAt else { return nil }
        let snapshot = try aggregateCachedAccounts(fetchedAt: fetchedAt)
        cachedSnapshot = snapshot
        return snapshot
    }

    func disconnect() throws {
        pendingTwoFactor = nil
        cachedSnapshot = nil
        cachedAccountPayloads = []
        cachedConnection = nil
        lastUsageRefreshAt = nil
        lastSuccessfulUsageRefreshAt = nil
        supportsUsageRefresh = true
        hasLoadedSavedConnection = true
        try sessionStore.delete()
        try connectionStore.delete()
    }

    func cancelTwoFactor() {
        pendingTwoFactor = nil
    }

    private func aggregateCachedAccounts(fetchedAt: Date) throws -> Sub2APIPoolSnapshot {
        let tiers = try savedTiers()
        return Sub2APIPoolAggregator.aggregate(
            accounts: cachedAccountPayloads.map { payload in
                payload.snapshot(
                    now: fetchedAt,
                    capacityTier: tiers[payload.id]
                )
            },
            fetchedAt: fetchedAt,
            staleAfter: staleAfter
        )
    }

    private func shouldRefreshUsage(at date: Date) -> Bool {
        guard supportsUsageRefresh else { return false }
        guard let lastUsageRefreshAt else { return true }
        return date.timeIntervalSince(lastUsageRefreshAt) >= usageRefreshInterval
    }

    private func refreshAndVerifyUsage(
        baseURL: URL,
        baselinePayloads initialBaseline: [Sub2APIAccountPayload],
        startedAt: Date
    ) async throws -> [Sub2APIAccountPayload] {
        var baselinePayloads = initialBaseline

        for poolAttempt in 0..<2 {
            let accountIDs = activePhysicalAccountIDs(in: baselinePayloads)
            guard !accountIDs.isEmpty else { return baselinePayloads }

            try await client.refreshAccountUsage(baseURL: baseURL, accountIDs: accountIDs.sorted())
            let readback = try await waitForVerifiedUsage(
                baseURL: baseURL,
                baselinePayloads: baselinePayloads,
                startedAt: startedAt
            )
            switch readback {
            case .verified(let payloads):
                return payloads
            case .accountSetChanged(let payloads):
                guard poolAttempt == 0 else {
                    throw Sub2APIError.accountPoolChangedDuringRefresh
                }
                baselinePayloads = payloads
            case .incomplete(let refreshed, let total):
                throw Sub2APIError.usageRefreshIncomplete(refreshed: refreshed, total: total)
            }
        }

        throw Sub2APIError.accountPoolChangedDuringRefresh
    }

    private func waitForVerifiedUsage(
        baseURL: URL,
        baselinePayloads: [Sub2APIAccountPayload],
        startedAt: Date
    ) async throws -> UsageReadbackResult {
        let baselineByID = Dictionary(
            baselinePayloads.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let expectedIDs = activePhysicalAccountIDs(in: baselinePayloads)
        var latestPayloads = baselinePayloads
        var latestVerifiedCount = 0

        for attempt in 0..<usageReadbackAttempts {
            try Task.checkCancellation()
            latestPayloads = try await client.fetchAccounts(
                baseURL: baseURL,
                pageSize: pageSize,
                maximumPages: maximumPages
            )
            let currentIDs = activePhysicalAccountIDs(in: latestPayloads)
            guard currentIDs == expectedIDs else {
                return .accountSetChanged(latestPayloads)
            }

            let currentByID = Dictionary(
                latestPayloads.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let verificationDate = Date()
            latestVerifiedCount = expectedIDs.reduce(into: 0) { count, accountID in
                guard let baseline = baselineByID[accountID],
                      let current = currentByID[accountID],
                      usageIsVerified(
                          current,
                          comparedWith: baseline,
                          startedAt: startedAt,
                          verificationDate: verificationDate
                      )
                else { return }
                count += 1
            }
            if latestVerifiedCount == expectedIDs.count {
                return .verified(latestPayloads)
            }

            if attempt + 1 < usageReadbackAttempts {
                try await Task.sleep(for: usageReadbackDelay)
            }
        }

        return .incomplete(refreshed: latestVerifiedCount, total: expectedIDs.count)
    }

    private func usageIsVerified(
        _ current: Sub2APIAccountPayload,
        comparedWith baseline: Sub2APIAccountPayload,
        startedAt: Date,
        verificationDate: Date
    ) -> Bool {
        let currentSnapshot = current.snapshot(now: verificationDate)
        if !currentSnapshot.schedulable
            || currentSnapshot.hasExplicitZeroCapacityState(at: verificationDate) {
            return true
        }

        guard let fiveHour = currentSnapshot.fiveHourUsedPercent,
              let sevenDay = currentSnapshot.sevenDayUsedPercent,
              fiveHour.isFinite,
              sevenDay.isFinite,
              (0...100).contains(fiveHour),
              (0...100).contains(sevenDay),
              let currentUpdatedAt = currentSnapshot.usageUpdatedAt
        else {
            return false
        }

        let baselineUpdatedAt = baseline.snapshot(now: verificationDate).usageUpdatedAt
        guard let baselineUpdatedAt else {
            return true
        }
        return currentUpdatedAt > baselineUpdatedAt
            || currentUpdatedAt >= startedAt.addingTimeInterval(-5)
    }

    private func activePhysicalAccountIDs(
        in payloads: [Sub2APIAccountPayload]
    ) -> Set<Int64> {
        Set(payloads.compactMap { payload in
            payload.parentAccountID == nil && payload.status == "active" ? payload.id : nil
        })
    }

    private func savedTiers() throws -> [Int64: Sub2APICapacityTier] {
        guard let serverIdentifier = cachedConnection?.baseURL.absoluteString else { return [:] }
        return try capacityConfigurationStore.load()?
            .tiersByAccountID(serverIdentifier: serverIdentifier) ?? [:]
    }

    private func physicalAccountPayloads() -> [Sub2APIAccountPayload] {
        Dictionary(
            cachedAccountPayloads.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        .values
        .filter { $0.parentAccountID == nil }
        .sorted { $0.id < $1.id }
    }
}

private enum UsageReadbackResult {
    case verified([Sub2APIAccountPayload])
    case accountSetChanged([Sub2APIAccountPayload])
    case incomplete(refreshed: Int, total: Int)
}

private extension Sub2APIAccountSnapshot {
    func hasExplicitZeroCapacityState(at date: Date) -> Bool {
        (rateLimitResetAt.map { $0 > date } ?? false)
            || (overloadUntil.map { $0 > date } ?? false)
            || (tempUnschedulableUntil.map { $0 > date } ?? false)
            || (fiveHourUsedPercent.map { $0 == 100 } ?? false)
            || (sevenDayUsedPercent.map { $0 == 100 } ?? false)
    }
}

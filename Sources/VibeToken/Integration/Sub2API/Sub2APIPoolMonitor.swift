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

    private var cachedSnapshot: Sub2APIPoolSnapshot?
    private var cachedAccountPayloads: [Sub2APIAccountPayload] = []
    private var cachedConnection: Sub2APIConnection?
    private var lastUsageRefreshAt: Date?
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
        usageRefreshInterval: TimeInterval
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
        let usageAccountIDs = payloads.compactMap { payload in
            payload.parentAccountID == nil && payload.status == "active" ? payload.id : nil
        }
        if shouldRefreshUsage(at: fetchedAt), !usageAccountIDs.isEmpty {
            lastUsageRefreshAt = fetchedAt
            do {
                try await client.refreshAccountUsage(
                    baseURL: connection.baseURL,
                    accountIDs: usageAccountIDs
                )
                payloads = try await client.fetchAccounts(
                    baseURL: connection.baseURL,
                    pageSize: pageSize,
                    maximumPages: maximumPages
                )
            } catch Sub2APIError.incompatibleServer {
                supportsUsageRefresh = false
            } catch Sub2APIError.unauthorized {
                throw Sub2APIError.unauthorized
            } catch {
                PrivacyLog.relay.warning("Sub2API usage refresh failed; using account snapshot")
            }
        }
        cachedAccountPayloads = payloads
        let snapshot = try aggregateCachedAccounts(fetchedAt: fetchedAt)
        cachedSnapshot = snapshot
        return snapshot
    }

    func capacityOptions() throws -> [Sub2APIAccountCapacityOption] {
        let tiers = try savedTiers()
        return physicalAccountPayloads().map { payload in
            Sub2APIAccountCapacityOption(
                accountID: payload.id,
                displayName: payload.capacityDisplayName,
                detectedPlan: payload.detectedPlan,
                selectedTier: payload.resolvedCapacityTier(
                    configuredTier: tiers[payload.id]
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

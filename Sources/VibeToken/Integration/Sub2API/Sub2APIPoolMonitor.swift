import Foundation

actor Sub2APIPoolMonitor {
    private let client: any Sub2APIClientServing
    private let sessionStore: any Sub2APISessionStoring
    private let connectionStore: any Sub2APIConnectionStoring
    private let pageSize: Int
    private let maximumPages: Int
    private let staleAfter: TimeInterval
    private let minimumRefreshInterval: TimeInterval

    private var cachedSnapshot: Sub2APIPoolSnapshot?
    private var cachedConnection: Sub2APIConnection?
    private var hasLoadedSavedConnection = false
    private var pendingTwoFactor: (connection: Sub2APIConnection, tempToken: String)?

    init(
        client: any Sub2APIClientServing,
        sessionStore: any Sub2APISessionStoring,
        connectionStore: any Sub2APIConnectionStoring,
        pageSize: Int,
        maximumPages: Int,
        staleAfter: TimeInterval,
        minimumRefreshInterval: TimeInterval
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.connectionStore = connectionStore
        self.pageSize = pageSize
        self.maximumPages = maximumPages
        self.staleAfter = staleAfter
        self.minimumRefreshInterval = minimumRefreshInterval
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
        let payloads = try await client.fetchAccounts(
            baseURL: connection.baseURL,
            pageSize: pageSize,
            maximumPages: maximumPages
        )
        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: payloads.map { $0.snapshot(now: fetchedAt) },
            fetchedAt: fetchedAt,
            staleAfter: staleAfter
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    func disconnect() throws {
        pendingTwoFactor = nil
        cachedSnapshot = nil
        cachedConnection = nil
        hasLoadedSavedConnection = true
        try sessionStore.delete()
        try connectionStore.delete()
    }

    func cancelTwoFactor() {
        pendingTwoFactor = nil
    }
}

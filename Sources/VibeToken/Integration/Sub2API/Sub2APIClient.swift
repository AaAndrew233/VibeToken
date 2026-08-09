import Foundation

protocol Sub2APIHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: Sub2APIHTTPDataLoading {}

protocol Sub2APIClientServing: Sendable {
    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult
    func completeTwoFactor(baseURL: URL, tempToken: String, code: String) async throws -> Sub2APISession
    func fetchAccounts(baseURL: URL, pageSize: Int, maximumPages: Int) async throws -> [Sub2APIAccountPayload]
    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws
}

actor Sub2APIClient: Sub2APIClientServing {
    private let loader: any Sub2APIHTTPDataLoading
    private let sessionStore: any Sub2APISessionStoring
    private let requestTimeout: TimeInterval
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        loader: any Sub2APIHTTPDataLoading,
        sessionStore: any Sub2APISessionStoring,
        requestTimeout: TimeInterval
    ) {
        self.loader = loader
        self.sessionStore = sessionStore
        self.requestTimeout = requestTimeout
    }

    init(
        sessionStore: any Sub2APISessionStoring,
        requestTimeout: TimeInterval
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.init(
            loader: URLSession(configuration: configuration),
            sessionStore: sessionStore,
            requestTimeout: requestTimeout
        )
    }

    func login(baseURL: URL, email: String, password: String) async throws -> Sub2APILoginResult {
        let body = try encoder.encode(LoginRequest(email: email, password: password))
        let payload: Sub2APILoginPayload = try await send(
            baseURL: baseURL,
            path: "auth/login",
            method: "POST",
            body: body,
            accessToken: nil,
            authenticationError: .invalidCredentials
        )

        if payload.requiresTwoFactor == true {
            guard let tempToken = payload.tempToken, !tempToken.isEmpty else {
                throw Sub2APIError.unexpectedResponse
            }
            return .requiresTwoFactor(
                tempToken: tempToken,
                maskedEmail: payload.maskedEmail ?? ""
            )
        }

        guard payload.user?.role == "admin" else {
            throw Sub2APIError.administratorRequired
        }
        let session = try makeSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresIn: payload.expiresIn
        )
        try sessionStore.save(session)
        return .authenticated(session)
    }

    func completeTwoFactor(baseURL: URL, tempToken: String, code: String) async throws -> Sub2APISession {
        let body = try encoder.encode(TwoFactorRequest(tempToken: tempToken, code: code))
        let payload: Sub2APILoginPayload = try await send(
            baseURL: baseURL,
            path: "auth/login/2fa",
            method: "POST",
            body: body,
            accessToken: nil,
            authenticationError: .twoFactorExpired
        )
        guard payload.user?.role == "admin" else {
            throw Sub2APIError.administratorRequired
        }
        let session = try makeSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresIn: payload.expiresIn
        )
        try sessionStore.save(session)
        return session
    }

    func fetchAccounts(baseURL: URL, pageSize: Int, maximumPages: Int) async throws -> [Sub2APIAccountPayload] {
        var session = try await validSession(baseURL: baseURL)
        var accountOrder: [Int64] = []
        var accountsByID: [Int64: Sub2APIAccountPayload] = [:]
        var page = 1
        var retriedAuthorizationForPage = false

        while page <= maximumPages {
            do {
                let payload: Sub2APIPaginatedAccounts = try await send(
                    baseURL: baseURL,
                    path: "admin/accounts",
                    method: "GET",
                    queryItems: [
                        URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "page_size", value: String(pageSize)),
                        URLQueryItem(name: "platform", value: "openai"),
                        URLQueryItem(name: "type", value: "oauth")
                    ],
                    accessToken: session.accessToken
                )
                for account in payload.items {
                    if accountsByID[account.id] == nil {
                        accountOrder.append(account.id)
                    }
                    accountsByID[account.id] = account
                }
                if page >= payload.pages || accountsByID.count >= payload.total {
                    return accountOrder.compactMap { accountsByID[$0] }
                }
                page += 1
                retriedAuthorizationForPage = false
            } catch Sub2APIError.unauthorized {
                guard !retriedAuthorizationForPage else { throw Sub2APIError.unauthorized }
                session = try await refreshSession(baseURL: baseURL, current: session)
                retriedAuthorizationForPage = true
                continue
            }
        }
        throw Sub2APIError.tooManyAccounts
    }

    func refreshAccountUsage(baseURL: URL, accountIDs: [Int64]) async throws {
        let normalizedIDs = Array(Set(accountIDs.filter { $0 > 0 })).sorted()
        guard !normalizedIDs.isEmpty else { return }

        let body = try encoder.encode(BatchUsageRequest(accountIDs: normalizedIDs, force: false))
        var session = try await validSession(baseURL: baseURL)
        var retriedAuthorization = false

        while true {
            do {
                let _: BatchUsageResponse = try await send(
                    baseURL: baseURL,
                    path: "admin/accounts/usage/batch",
                    method: "POST",
                    body: body,
                    accessToken: session.accessToken
                )
                return
            } catch Sub2APIError.unauthorized {
                guard !retriedAuthorization else { throw Sub2APIError.unauthorized }
                session = try await refreshSession(baseURL: baseURL, current: session)
                retriedAuthorization = true
            } catch Sub2APIError.incompatibleServer {
                break
            }
        }

        try await refreshReleasedAccountUsage(
            baseURL: baseURL,
            accountIDs: normalizedIDs,
            session: session,
            authorizationAlreadyRetried: retriedAuthorization
        )
    }

    private func refreshReleasedAccountUsage(
        baseURL: URL,
        accountIDs: [Int64],
        session initialSession: Sub2APISession,
        authorizationAlreadyRetried: Bool
    ) async throws {
        var session = initialSession
        var pendingAccountIDs = accountIDs
        var retriedAuthorization = authorizationAlreadyRetried

        while !pendingAccountIDs.isEmpty {
            let results = try await refreshReleasedAccountUsage(
                baseURL: baseURL,
                accountIDs: pendingAccountIDs,
                accessToken: session.accessToken
            )
            if results.contains(where: { $0.isIncompatibleServer }) {
                throw Sub2APIError.incompatibleServer
            }

            let unauthorizedAccountIDs = results.compactMap(\.unauthorizedAccountID)
            guard !unauthorizedAccountIDs.isEmpty else { return }
            guard !retriedAuthorization else { throw Sub2APIError.unauthorized }

            session = try await refreshSession(baseURL: baseURL, current: session)
            pendingAccountIDs = unauthorizedAccountIDs
            retriedAuthorization = true
        }
    }

    private func refreshReleasedAccountUsage(
        baseURL: URL,
        accountIDs: [Int64],
        accessToken: String
    ) async throws -> [AccountUsageRefreshResult] {
        var results: [AccountUsageRefreshResult] = []
        for chunkStart in stride(from: 0, to: accountIDs.count, by: 6) {
            let chunkEnd = min(chunkStart + 6, accountIDs.count)
            let chunk = accountIDs[chunkStart..<chunkEnd]
            let chunkResults = try await withThrowingTaskGroup(
                of: AccountUsageRefreshResult.self,
                returning: [AccountUsageRefreshResult].self
            ) { group in
                for accountID in chunk {
                    group.addTask {
                        try await self.refreshReleasedAccountUsage(
                            baseURL: baseURL,
                            accountID: accountID,
                            accessToken: accessToken
                        )
                    }
                }

                var collected: [AccountUsageRefreshResult] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }
            results.append(contentsOf: chunkResults)
        }
        return results
    }

    private func refreshReleasedAccountUsage(
        baseURL: URL,
        accountID: Int64,
        accessToken: String
    ) async throws -> AccountUsageRefreshResult {
        do {
            let _: AccountUsageRefreshResponse = try await send(
                baseURL: baseURL,
                path: "admin/accounts/\(accountID)/usage",
                method: "GET",
                queryItems: [URLQueryItem(name: "source", value: "active")],
                accessToken: accessToken
            )
            return .refreshed
        } catch is CancellationError {
            throw CancellationError()
        } catch Sub2APIError.unauthorized {
            return .unauthorized(accountID)
        } catch Sub2APIError.incompatibleServer {
            return .incompatibleServer
        } catch {
            return .failed
        }
    }

    private func validSession(baseURL: URL) async throws -> Sub2APISession {
        guard let session = try sessionStore.load() else { throw Sub2APIError.unauthorized }
        if let expiresAt = session.expiresAt,
           expiresAt.timeIntervalSinceNow < 60 {
            return try await refreshSession(baseURL: baseURL, current: session)
        }
        return session
    }

    private func refreshSession(baseURL: URL, current: Sub2APISession) async throws -> Sub2APISession {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw Sub2APIError.unauthorized
        }
        let body = try encoder.encode(RefreshRequest(refreshToken: refreshToken))
        let payload: Sub2APIRefreshPayload = try await send(
            baseURL: baseURL,
            path: "auth/refresh",
            method: "POST",
            body: body,
            accessToken: nil
        )
        let session = try makeSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? current.refreshToken,
            expiresIn: payload.expiresIn
        )
        try sessionStore.save(session)
        return session
    }

    private func makeSession(
        accessToken: String?,
        refreshToken: String?,
        expiresIn: Int?
    ) throws -> Sub2APISession {
        guard let accessToken, !accessToken.isEmpty else {
            throw Sub2APIError.unexpectedResponse
        }
        return Sub2APISession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval(max(0, $0))) }
        )
    }

    private func send<Payload: Decodable & Sendable>(
        baseURL: URL,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        accessToken: String?,
        authenticationError: Sub2APIError = .unauthorized
    ) async throws -> Payload {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw Sub2APIError.invalidServerURL }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Admin-UI-Request")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw Sub2APIError.requestTimedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Sub2APIError.serverUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw Sub2APIError.unexpectedResponse
        }
        if http.statusCode == 401 {
            throw authenticationError
        }
        if http.statusCode == 404 {
            throw Sub2APIError.incompatibleServer
        }

        let envelope: Sub2APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(Sub2APIEnvelope<Payload>.self, from: data)
        } catch {
            PrivacyLog.relay.error(
                "Sub2API response decode failed for \(path, privacy: .public): \(self.decodingIssue(error), privacy: .public)"
            )
            throw Sub2APIError.unexpectedResponse
        }
        let normalizedMessage = envelope.message.lowercased()
        if normalizedMessage.contains("captcha") || normalizedMessage.contains("turnstile") {
            throw Sub2APIError.captchaRequired
        }
        if http.statusCode == 400 || http.statusCode == 403 || envelope.code == 400 || envelope.code == 403 {
            throw authenticationError
        }
        guard (200..<300).contains(http.statusCode), envelope.code == 0 else {
            throw Sub2APIError.serverUnavailable
        }
        guard let payload = envelope.data else { throw Sub2APIError.unexpectedResponse }
        return payload
    }

    private func decodingIssue(_ error: Error) -> String {
        switch error {
        case .typeMismatch(let type, let context) as DecodingError:
            return "typeMismatch(\(String(describing: type))) at \(codingPath(context.codingPath))"
        case .valueNotFound(let type, let context) as DecodingError:
            return "valueNotFound(\(String(describing: type))) at \(codingPath(context.codingPath))"
        case .keyNotFound(let key, let context) as DecodingError:
            return "keyNotFound(\(key.stringValue)) at \(codingPath(context.codingPath))"
        case .dataCorrupted(let context) as DecodingError:
            return "dataCorrupted at \(codingPath(context.codingPath))"
        default:
            return "nonDecodingError"
        }
    }

    private func codingPath(_ path: [any CodingKey]) -> String {
        let components = path.map { key in
            key.intValue.map { "[\($0)]" } ?? key.stringValue
        }
        return components.isEmpty ? "root" : components.joined(separator: ".")
    }
}

private struct LoginRequest: Encodable {
    let email: String
    let password: String
}

private struct TwoFactorRequest: Encodable {
    let tempToken: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case tempToken = "temp_token"
        case code = "totp_code"
    }
}

private struct RefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct BatchUsageRequest: Encodable {
    let accountIDs: [Int64]
    let force: Bool

    enum CodingKeys: String, CodingKey {
        case accountIDs = "account_ids"
        case force
    }
}

private struct BatchUsageResponse: Decodable, Sendable {}

private struct AccountUsageRefreshResponse: Decodable, Sendable {}

private enum AccountUsageRefreshResult: Sendable {
    case refreshed
    case unauthorized(Int64)
    case incompatibleServer
    case failed

    var unauthorizedAccountID: Int64? {
        guard case .unauthorized(let accountID) = self else { return nil }
        return accountID
    }

    var isIncompatibleServer: Bool {
        guard case .incompatibleServer = self else { return false }
        return true
    }
}

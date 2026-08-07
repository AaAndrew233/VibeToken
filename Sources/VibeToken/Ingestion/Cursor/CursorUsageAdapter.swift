import Foundation
import GRDB

struct CursorHTTPResult: Sendable {
    let data: Data
    let statusCode: Int
}

protocol CursorUsageTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CursorHTTPResult
}

struct URLSessionCursorUsageTransport: CursorUsageTransport {
    func send(_ request: URLRequest) async throws -> CursorHTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CursorUsageError.invalidResponse
        }
        return CursorHTTPResult(data: data, statusCode: response.statusCode)
    }
}

enum CursorUsageError: LocalizedError, Sendable {
    case invalidResponse
    case authorizationRejected
    case serverStatus(Int)
    case malformedExport

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Cursor returned an invalid response"
        case .authorizationRejected:
            "Cursor authorization expired; sign in to Cursor again"
        case let .serverStatus(statusCode):
            "Cursor usage export failed with HTTP \(statusCode)"
        case .malformedExport:
            "Cursor usage export format is not supported"
        }
    }
}

actor CursorUsageAdapter: UsageSourceAdapter {
    private struct UsageKey: Hashable {
        let date: Date
        let model: String
    }

    private struct MutableUsage {
        var input: Int64 = 0
        var cachedInput: Int64 = 0
        var cacheWrite: Int64 = 0
        var output: Int64 = 0
    }

    nonisolated let sourceIdentifier = "cursor"
    nonisolated let displayName = "Cursor"
    nonisolated let accuracy = UsageAccuracy.exact

    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let sessionCookieName = "WorkosCursorSessionToken"
    private static let usageExportURL = URL(
        string: "https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens"
    )!

    private let repository: UsageRepository
    private let stateDatabaseURL: URL
    private let transport: any CursorUsageTransport
    private let minimumFetchInterval: TimeInterval
    private var lastFetchAttemptAt: Date?

    init(
        configuration _: AppConfiguration,
        repository: UsageRepository,
        stateDatabaseURL: URL? = nil,
        transport: any CursorUsageTransport = URLSessionCursorUsageTransport(),
        minimumFetchInterval: TimeInterval = 5 * 60,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.repository = repository
        self.stateDatabaseURL = stateDatabaseURL ?? homeDirectory.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            isDirectory: false
        )
        self.transport = transport
        self.minimumFetchInterval = max(0, minimumFetchInterval)
    }

    func discover() async -> Bool {
        FileManager.default.fileExists(atPath: stateDatabaseURL.path)
    }

    func ingestRecentSessions(now: Date) async throws {
        guard await discover() else { return }
        if let lastFetchAttemptAt,
           now >= lastFetchAttemptAt,
           now.timeIntervalSince(lastFetchAttemptAt) < minimumFetchInterval {
            return
        }
        lastFetchAttemptAt = now

        guard let token = try readAccessToken() else { return }
        let csv = try await fetchUsageCSV(token: token)
        let events = try Self.events(fromCSV: csv)
        try repository.persistLocalEvents(
            events,
            sourceIdentifier: sourceIdentifier,
            sourceDisplayName: displayName,
            sourceKind: "cursor_cloud_csv",
            accuracy: accuracy,
            allowDecreasingTotals: true
        )
    }

    func watchTargets(now _: Date) async throws -> UsageWatchTargets {
        let files = databaseFiles().filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return UsageWatchTargets(
            fileURLs: files,
            directoryURLs: [stateDatabaseURL.deletingLastPathComponent()]
        )
    }

    private func readAccessToken() throws -> String? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        let queue = try DatabaseQueue(path: stateDatabaseURL.path, configuration: configuration)
        return try queue.read { database in
            let value = try String.fetchOne(
                database,
                sql: "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                arguments: [Self.accessTokenKey]
            )
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private func fetchUsageCSV(token: String) async throws -> Data {
        let subject = Self.jwtSubject(token)
        let userIdentifier = subject?.split(separator: "|").last.map(String.init)
        var authorizationHeaders: [[String: String]] = []
        if let subject {
            authorizationHeaders.append([
                "Cookie": "\(Self.sessionCookieName)=\(subject)%3A%3A\(token)"
            ])
        }
        if let userIdentifier, userIdentifier != subject {
            authorizationHeaders.append([
                "Cookie": "\(Self.sessionCookieName)=\(userIdentifier)%3A%3A\(token)"
            ])
        }
        authorizationHeaders.append([
            "Cookie": "\(Self.sessionCookieName)=\(token)"
        ])
        authorizationHeaders.append(["Authorization": "Bearer \(token)"])

        for authorizationHeader in authorizationHeaders {
            var request = URLRequest(url: Self.usageExportURL)
            request.timeoutInterval = 10
            request.setValue("text/csv,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue(
                "https://cursor.com/dashboard?tab=usage",
                forHTTPHeaderField: "Referer"
            )
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            authorizationHeader.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

            let result = try await transport.send(request)
            if (200..<300).contains(result.statusCode) { return result.data }
            if result.statusCode != 401 && result.statusCode != 403 {
                throw CursorUsageError.serverStatus(result.statusCode)
            }
        }
        throw CursorUsageError.authorizationRejected
    }

    private static func events(fromCSV data: Data) throws -> [LocalUsageEvent] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CursorUsageError.malformedExport
        }
        let rows = CSVRows.parse(text)
        guard let header = rows.first else { return [] }
        let normalizedHeader = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func column(_ name: String) -> Int? {
            normalizedHeader.firstIndex(of: name)
        }
        guard let dateColumn = column("Date"),
              let modelColumn = column("Model") else {
            throw CursorUsageError.malformedExport
        }
        let inputWithCacheWriteColumn = column("Input (w/ Cache Write)")
        let inputWithoutCacheWriteColumn = column("Input (w/o Cache Write)")
        let cacheReadColumn = column("Cache Read")
        let outputColumn = column("Output Tokens")

        var grouped: [UsageKey: MutableUsage] = [:]
        for row in rows.dropFirst() {
            guard let dateText = row[safe: dateColumn],
                  let date = csvDate(dateText),
                  let rawModel = row[safe: modelColumn],
                  let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                continue
            }
            let key = UsageKey(date: date, model: model)
            var usage = grouped[key] ?? MutableUsage()
            usage.input = saturatingAdd(
                usage.input,
                csvCount(row[safe: inputWithoutCacheWriteColumn])
            )
            usage.cacheWrite = saturatingAdd(
                usage.cacheWrite,
                csvCount(row[safe: inputWithCacheWriteColumn])
            )
            usage.cachedInput = saturatingAdd(
                usage.cachedInput,
                csvCount(row[safe: cacheReadColumn])
            )
            usage.output = saturatingAdd(
                usage.output,
                csvCount(row[safe: outputColumn])
            )
            grouped[key] = usage
        }

        return grouped.compactMap { key, usage in
            let counters = LocalUsageValue.counters(
                input: usage.input,
                cachedInput: usage.cachedInput,
                cacheWrite: usage.cacheWrite,
                output: usage.output,
                reasoning: 0
            )
            guard counters.totalTokens > 0 else { return nil }
            let stableIdentity = StableHash.string(
                "\(key.date.timeIntervalSince1970)|\(key.model)"
            )
            return LocalUsageEvent(
                idempotencyKey: "cursor:\(stableIdentity)",
                sessionIdentifier: "cursor-cloud-\(Int64(key.date.timeIntervalSince1970))",
                model: key.model,
                projectLabel: nil,
                occurredAt: key.date,
                counters: counters,
                rawSchemaVersion: "cursor-usage-export-csv-v1"
            )
        }
    }

    private static func csvDate(_ rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: value) { return date }
        }
        return LocalUsageValue.date(value)
    }

    private static func csvCount(_ rawValue: String?) -> Int64 {
        guard let rawValue else { return 0 }
        let normalized = rawValue.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              decimal.isFinite,
              decimal > 0 else {
            return 0
        }
        let number = NSDecimalNumber(decimal: decimal)
        return number.compare(NSDecimalNumber(value: Int64.max)) == .orderedDescending
            ? Int64.max
            : max(0, number.int64Value)
    }

    private static func jwtSubject(_ token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = LocalUsageValue.dictionary(object) else {
            return nil
        }
        return LocalUsageValue.string(payload["sub"])
    }

    private func databaseFiles() -> [URL] {
        [
            stateDatabaseURL,
            URL(fileURLWithPath: stateDatabaseURL.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: stateDatabaseURL.path + "-shm", isDirectory: false)
        ]
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

private enum CSVRows {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            if isQuoted {
                if character == "\"" {
                    if nextIndex < text.endIndex, text[nextIndex] == "\"" {
                        field.append("\"")
                        index = text.index(after: nextIndex)
                        continue
                    }
                    isQuoted = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": isQuoted = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r": break
                default: field.append(character)
                }
            }
            index = nextIndex
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Collection {
    subscript(safe index: Index?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}

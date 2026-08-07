import Foundation
import GRDB

enum SQLiteUsageTool: CaseIterable, Hashable, Sendable {
    case dimAgent
    case mimoCode
    case hermes
    case zCode

    var sourceIdentifier: String {
        switch self {
        case .dimAgent: "dimagent"
        case .mimoCode: "mimocode"
        case .hermes: "hermes"
        case .zCode: "zcode"
        }
    }

    var displayName: String {
        switch self {
        case .dimAgent: "DimAgent"
        case .mimoCode: "MiMoCode"
        case .hermes: "Hermes"
        case .zCode: "ZCode"
        }
    }
}

actor SQLiteUsageAdapter: UsageSourceAdapter {
    nonisolated let sourceIdentifier: String
    nonisolated let displayName: String
    nonisolated let accuracy = UsageAccuracy.exact

    private let tool: SQLiteUsageTool
    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let homeDirectory: URL
    private let environment: [String: String]
    private var knownSignatures: [URL: SQLiteUsageSignature] = [:]

    init(
        tool: SQLiteUsageTool,
        configuration: AppConfiguration,
        repository: UsageRepository,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.tool = tool
        sourceIdentifier = tool.sourceIdentifier
        displayName = tool.displayName
        self.configuration = configuration
        self.repository = repository
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func discover() async -> Bool {
        !databaseDescriptors().isEmpty
    }

    func ingestRecentSessions(now: Date) async throws {
        let descriptors = databaseDescriptors()
        guard !descriptors.isEmpty else { return }

        for descriptor in descriptors {
            try Task.checkCancellation()
            guard let signature = SQLiteUsageSignature(databaseURL: descriptor.url),
                  knownSignatures[descriptor.url] != signature else {
                continue
            }
            let events = try SQLiteUsageParser.events(
                for: tool,
                descriptor: descriptor,
                now: now,
                configuration: configuration
            )
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_sqlite",
                accuracy: accuracy,
                allowDecreasingTotals: true
            )
            knownSignatures[descriptor.url] = signature
            await Task.yield()
        }
    }

    func watchTargets(now _: Date) async throws -> UsageWatchTargets {
        let descriptors = databaseDescriptors()
        let files = descriptors.flatMap { descriptor in
            SQLiteUsageSignature.databaseFiles(descriptor.url).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        return UsageWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: Array(Set(descriptors.map { $0.url.deletingLastPathComponent() }))
        )
    }

    private func databaseDescriptors() -> [SQLiteUsageDescriptor] {
        SQLiteUsageParser.databaseDescriptors(
            for: tool,
            homeDirectory: homeDirectory,
            environment: environment
        ).filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }
}

struct SQLiteUsageDescriptor: Sendable {
    let url: URL
    let profile: String?
}

private struct SQLiteUsageSignature: Equatable, Sendable {
    let size: UInt64
    let modificationDate: Date?

    init?(databaseURL: URL) {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var totalSize: UInt64 = 0
        var latestDate: Date?
        for fileURL in Self.databaseFiles(databaseURL) {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ]) else {
                continue
            }
            let (nextSize, overflow) = totalSize.addingReportingOverflow(
                UInt64(max(0, values.fileSize ?? 0))
            )
            totalSize = overflow ? UInt64.max : nextSize
            if let date = values.contentModificationDate,
               latestDate == nil || date > latestDate! {
                latestDate = date
            }
        }
        size = totalSize
        modificationDate = latestDate
    }

    static func databaseFiles(_ databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
    }
}

enum SQLiteUsageParser {
    static func databaseDescriptors(
        for tool: SQLiteUsageTool,
        homeDirectory: URL,
        environment: [String: String]
    ) -> [SQLiteUsageDescriptor] {
        switch tool {
        case .dimAgent:
            let url: URL
            if let override = absoluteURL(environment["VIBETOKEN_DIMAGENT_DB"], home: homeDirectory) {
                url = override
            } else if let dimHome = absoluteURL(environment["DIMCODE_HOME"], home: homeDirectory) {
                url = dimHome.appendingPathComponent("dimcode.sqlite")
            } else {
                url = homeDirectory.appendingPathComponent(".dimcode/v2/dimcode.sqlite")
            }
            return [SQLiteUsageDescriptor(url: url, profile: nil)]

        case .mimoCode:
            let dataHome = absoluteURL(environment["MIMOCODE_HOME"], home: homeDirectory)?
                .appendingPathComponent("data", isDirectory: true)
                ?? absoluteURL(environment["XDG_DATA_HOME"], home: homeDirectory)?
                    .appendingPathComponent("mimocode", isDirectory: true)
                ?? homeDirectory.appendingPathComponent(".local/share/mimocode", isDirectory: true)
            let rawDatabase = environment["MIMOCODE_DB"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let databaseURL: URL
            if let rawDatabase, !rawDatabase.isEmpty {
                databaseURL = rawDatabase.hasPrefix("/")
                    ? URL(fileURLWithPath: rawDatabase)
                    : dataHome.appendingPathComponent(rawDatabase)
            } else {
                databaseURL = dataHome.appendingPathComponent("mimocode.db")
            }
            return [SQLiteUsageDescriptor(url: databaseURL, profile: nil)]

        case .hermes:
            let hermesHome = absoluteURL(environment["HERMES_HOME"], home: homeDirectory)
                ?? homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
            var descriptors = [SQLiteUsageDescriptor(
                url: hermesHome.appendingPathComponent("state.db"),
                profile: "default"
            )]
            let profiles = hermesHome.appendingPathComponent("profiles", isDirectory: true)
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: profiles,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) {
                descriptors.append(contentsOf: entries.compactMap { entry in
                    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
                    return SQLiteUsageDescriptor(
                        url: entry.appendingPathComponent("state.db"),
                        profile: entry.lastPathComponent
                    )
                })
            }
            return descriptors

        case .zCode:
            return [SQLiteUsageDescriptor(
                url: homeDirectory.appendingPathComponent(".zcode/cli/db/db.sqlite"),
                profile: nil
            )]
        }
    }

    static func events(
        for tool: SQLiteUsageTool,
        descriptor: SQLiteUsageDescriptor,
        now: Date,
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        var databaseConfiguration = Configuration()
        databaseConfiguration.readonly = true
        databaseConfiguration.busyMode = .timeout(2)
        let queue = try DatabaseQueue(path: descriptor.url.path, configuration: databaseConfiguration)
        let historyStart = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        switch tool {
        case .dimAgent:
            return try dimAgentEvents(
                queue: queue,
                historyStart: historyStart,
                limit: configuration.maximumUsageSourceFiles
            )
        case .mimoCode:
            return try mimoCodeEvents(
                queue: queue,
                historyStart: historyStart,
                limit: configuration.maximumUsageSourceFiles
            )
        case .hermes:
            return try hermesEvents(
                queue: queue,
                profile: descriptor.profile ?? "default",
                historyStart: historyStart,
                limit: configuration.maximumUsageSourceFiles
            )
        case .zCode:
            return try zCodeEvents(
                queue: queue,
                historyStart: historyStart,
                limit: configuration.maximumUsageSourceFiles
            )
        }
    }

    private static func dimAgentEvents(
        queue: DatabaseQueue,
        historyStart: Date,
        limit: Int
    ) throws -> [LocalUsageEvent] {
        let rows = try queue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT u.ledgerId AS ledger_id, u.runId AS run_id,
                           u.providerId AS provider_id, u.modelId AS model_id,
                           u.sessionId AS session_id, u.usage AS usage,
                           u.cost AS cost, u.createdAt AS created_at, s.cwd AS cwd
                    FROM usage_ledger u
                    LEFT JOIN sessions s ON s.sessionId = u.sessionId
                    ORDER BY u.createdAt DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
        let originalSignatures = Set(rows.compactMap { row -> String? in
            let ledgerID: String? = row["ledger_id"]
            return isForkLedger(ledgerID) ? nil : dimAgentSignature(row)
        })
        var orphanForkSignatures = Set<String>()
        var events: [LocalUsageEvent] = []

        for row in rows {
            let signature = dimAgentSignature(row)
            let ledgerID: String? = row["ledger_id"]
            if isForkLedger(ledgerID),
               originalSignatures.contains(signature) || !orphanForkSignatures.insert(signature).inserted {
                continue
            }
            let createdAtText: String? = row["created_at"]
            guard let occurredAt = LocalUsageValue.date(createdAtText), occurredAt >= historyStart,
                  let rawUsage: String = row["usage"],
                  let data = rawUsage.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let usage = LocalUsageValue.dictionary(object) else {
                continue
            }
            let cached = LocalUsageValue.count(usage["cacheReadTokens"])
            let counters = LocalUsageValue.counters(
                input: max(0, LocalUsageValue.count(usage["promptTokens"]) - cached),
                cachedInput: cached,
                cacheWrite: LocalUsageValue.count(usage["cacheWriteTokens"]),
                output: LocalUsageValue.count(usage["completionTokens"]),
                reasoning: LocalUsageValue.count(usage["reasoningTokens"])
            )
            guard counters.totalTokens > 0 else { continue }
            let sessionID: String? = row["session_id"]
            let model: String? = row["model_id"]
            let identity = ledgerID?.isEmpty == false ? ledgerID! : StableHash.string(signature)
            let cwd: String? = row["cwd"]
            events.append(LocalUsageEvent(
                idempotencyKey: "dimagent:\(identity)",
                sessionIdentifier: sessionID ?? "unknown",
                model: model,
                projectLabel: FileUsageParser.projectName(cwd),
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "dimagent-usage-ledger-v1"
            ))
        }
        return events
    }

    private static func mimoCodeEvents(
        queue: DatabaseQueue,
        historyStart: Date,
        limit: Int
    ) throws -> [LocalUsageEvent] {
        let rows = try queue.read { database -> [Row] in
            let hasExternalImports = try database.tableExists("external_import")
            let join = hasExternalImports
                ? "LEFT JOIN external_import e ON e.session_id = message.session_id"
                : ""
            let filter = hasExternalImports ? "WHERE e.session_id IS NULL" : ""
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT message.id AS message_id, message.session_id AS session_id,
                           message.time_created AS created, message.data AS data,
                           session.directory AS directory
                    FROM message
                    JOIN session ON session.id = message.session_id
                    \(join)
                    \(filter)
                    ORDER BY message.time_created DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
        return rows.compactMap { row in
            guard let rawData: String = row["data"],
                  let data = rawData.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = LocalUsageValue.dictionary(object),
                  LocalUsageValue.string(record["role"]) == "assistant",
                  let tokens = LocalUsageValue.dictionary(record["tokens"]),
                  let occurredAt = LocalUsageValue.date(
                    LocalUsageValue.dictionary(record["time"])?["created"]
                  ) ?? LocalUsageValue.date(row["created"] as Any?),
                  occurredAt >= historyStart else {
                return nil
            }
            let cache = LocalUsageValue.dictionary(tokens["cache"])
            let counters = LocalUsageValue.counters(
                input: LocalUsageValue.count(tokens["input"]),
                cachedInput: LocalUsageValue.count(cache?["read"]),
                cacheWrite: LocalUsageValue.count(cache?["write"]),
                output: LocalUsageValue.count(tokens["output"]),
                reasoning: LocalUsageValue.count(tokens["reasoning"])
            )
            guard counters.totalTokens > 0 else { return nil }
            let messageID: String? = row["message_id"]
            let sessionID: String? = row["session_id"]
            let directory: String? = row["directory"]
            return LocalUsageEvent(
                idempotencyKey: "mimocode:\(messageID ?? StableHash.string(rawData))",
                sessionIdentifier: sessionID ?? "unknown",
                model: LocalUsageValue.string(record["modelID"]),
                projectLabel: FileUsageParser.projectName(directory),
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "mimocode-message-tokens-v1"
            )
        }
    }

    private static func hermesEvents(
        queue: DatabaseQueue,
        profile: String,
        historyStart: Date,
        limit: Int
    ) throws -> [LocalUsageEvent] {
        let rows = try queue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, model, started_at, input_tokens, output_tokens,
                           cache_read_tokens, reasoning_tokens
                    FROM sessions
                    WHERE input_tokens > 0 OR output_tokens > 0
                    ORDER BY started_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
        return rows.compactMap { row in
            let startedAt: Double? = row["started_at"]
            guard let startedAt, startedAt.isFinite else { return nil }
            let occurredAt = Date(timeIntervalSince1970: startedAt)
            guard occurredAt >= historyStart else { return nil }
            let input: Int64 = row["input_tokens"] ?? 0
            let output: Int64 = row["output_tokens"] ?? 0
            let cached: Int64 = row["cache_read_tokens"] ?? 0
            let reasoning: Int64 = row["reasoning_tokens"] ?? 0
            let counters = LocalUsageValue.counters(
                input: input,
                cachedInput: cached,
                cacheWrite: 0,
                output: output,
                reasoning: reasoning
            )
            guard counters.totalTokens > 0 else { return nil }
            let sessionID: String? = row["id"]
            let model: String? = row["model"]
            return LocalUsageEvent(
                idempotencyKey: "hermes:\(profile):\(sessionID ?? "unknown")",
                sessionIdentifier: "\(profile):\(sessionID ?? "unknown")",
                model: model,
                projectLabel: profile,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "hermes-session-cumulative-v1"
            )
        }
    }

    private static func zCodeEvents(
        queue: DatabaseQueue,
        historyStart: Date,
        limit: Int
    ) throws -> [LocalUsageEvent] {
        let rows = try queue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT message.id AS message_id, message.session_id AS session_id,
                           message.time_created AS created, message.data AS data,
                           session.directory AS session_directory
                    FROM message
                    LEFT JOIN session ON session.id = message.session_id
                    ORDER BY message.time_created DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
        return rows.compactMap { row in
            guard let rawData: String = row["data"],
                  let data = rawData.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = LocalUsageValue.dictionary(object),
                  LocalUsageValue.string(record["role"]) == "assistant",
                  let tokens = LocalUsageValue.dictionary(record["tokens"]),
                  let occurredAt = LocalUsageValue.date(row["created"] as Any?),
                  occurredAt >= historyStart else {
                return nil
            }
            let cache = LocalUsageValue.dictionary(tokens["cache"])
            let cached = LocalUsageValue.count(cache?["read"])
            let reasoning = LocalUsageValue.count(tokens["reasoning"])
            let counters = LocalUsageValue.counters(
                input: max(0, LocalUsageValue.count(tokens["input"]) - cached),
                cachedInput: cached,
                cacheWrite: LocalUsageValue.count(cache?["write"]),
                output: max(0, LocalUsageValue.count(tokens["output"]) - reasoning),
                reasoning: reasoning
            )
            guard counters.totalTokens > 0 else { return nil }
            let path = LocalUsageValue.dictionary(record["path"])
            let sessionDirectory: String? = row["session_directory"]
            let project = FileUsageParser.projectName(
                LocalUsageValue.string(path?["root"])
                    ?? LocalUsageValue.string(path?["cwd"])
                    ?? sessionDirectory
            )
            let messageID: String? = row["message_id"]
            let sessionID: String? = row["session_id"]
            return LocalUsageEvent(
                idempotencyKey: "zcode:\(messageID ?? StableHash.string(rawData))",
                sessionIdentifier: sessionID ?? "unknown",
                model: LocalUsageValue.string(record["modelID"]),
                projectLabel: project,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "zcode-message-tokens-v1"
            )
        }
    }

    private static func dimAgentSignature(_ row: Row) -> String {
        let fields: [String] = [
            row["run_id"] ?? "",
            row["provider_id"] ?? "",
            row["model_id"] ?? "",
            row["usage"] ?? "",
            row["created_at"] ?? ""
        ]
        return fields.joined(separator: "\u{0}")
    }

    private static func isForkLedger(_ ledgerID: String?) -> Bool {
        guard let ledgerID else { return false }
        return ledgerID.range(
            of: #"^ledger_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func absoluteURL(_ rawValue: String?, home: URL) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        if rawValue == "~" { return home }
        if rawValue.hasPrefix("~/") {
            return home.appendingPathComponent(String(rawValue.dropFirst(2)))
        }
        return URL(fileURLWithPath: rawValue)
    }
}

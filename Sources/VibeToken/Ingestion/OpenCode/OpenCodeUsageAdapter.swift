import Foundation
import GRDB

actor OpenCodeUsageAdapter: UsageSourceAdapter {
    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date?
    }

    nonisolated let sourceIdentifier = "opencode"
    nonisolated let displayName = "OpenCode"
    nonisolated let accuracy = UsageAccuracy.exact

    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let dataRoot: URL
    private let databasePageSize: Int
    private var knownDatabaseSignature: FileSignature?
    private var lastDatabaseRowID: Int64 = 0
    private var knownLegacySignatures: [URL: FileSignature] = [:]

    init(
        configuration: AppConfiguration,
        repository: UsageRepository,
        dataRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        databasePageSize: Int? = nil
    ) {
        self.configuration = configuration
        self.repository = repository
        self.databasePageSize = max(1, databasePageSize ?? configuration.usageDatabasePageSize)
        self.dataRoot = dataRoot ?? homeDirectory
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    func discover() async -> Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
            || Self.isDirectory(messagesDirectory)
    }

    func ingestRecentSessions(now: Date) async throws {
        guard await discover() else { return }
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                try ingestDatabase(now: now)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                PrivacyLog.ingestion.error(
                    "OpenCode database read failed; using legacy files: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                guard Self.isDirectory(messagesDirectory) else { throw error }
            }
        }
        try ingestLegacyFiles(now: now)
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        var files: [URL] = []
        files.append(contentsOf: databaseFiles().filter {
            FileManager.default.fileExists(atPath: $0.path)
        })
        files.append(contentsOf: legacyFiles(modifiedSince: modifiedSince))
        var directories = [dataRoot]
        if Self.isDirectory(messagesDirectory) { directories.append(messagesDirectory) }
        return UsageWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: directories.filter(Self.isDirectory)
        )
    }

    private func ingestDatabase(now: Date) throws {
        let signature = try databaseSignature()
        guard signature != knownDatabaseSignature else { return }
        if let previous = knownDatabaseSignature, signature.size < previous.size {
            lastDatabaseRowID = 0
        }

        var databaseConfiguration = Configuration()
        databaseConfiguration.readonly = true
        databaseConfiguration.busyMode = .timeout(2)
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: databaseConfiguration)
        var cursor = max(0, lastDatabaseRowID - 100)
        var persistedAnyPage = false
        let historyStart = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        let historyStartMilliseconds = Int64(historyStart.timeIntervalSince1970 * 1_000)

        while true {
            try Task.checkCancellation()
            let rows = try queue.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT rowid AS local_row_id, id, session_id, data
                        FROM message
                        WHERE rowid > ?
                          AND CAST(json_extract(data, '$.time.created') AS INTEGER) >= ?
                        ORDER BY rowid
                        LIMIT ?
                        """,
                    arguments: [cursor, historyStartMilliseconds, databasePageSize]
                )
            }
            guard !rows.isEmpty else { break }
            let events = rows.compactMap(Self.event(fromDatabaseRow:))
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_sqlite",
                accuracy: accuracy
            )
            persistedAnyPage = true
            cursor = rows.compactMap { row -> Int64? in row["local_row_id"] }.max() ?? cursor
            if rows.count < databasePageSize { break }
        }

        if !persistedAnyPage {
            try repository.persistLocalEvents(
                [],
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_sqlite",
                accuracy: accuracy
            )
        }
        let maximumRowID = try queue.read { database in
            try Int64.fetchOne(database, sql: "SELECT MAX(rowid) FROM message") ?? 0
        }
        lastDatabaseRowID = max(lastDatabaseRowID, cursor, maximumRowID)
        knownDatabaseSignature = signature
    }

    private func ingestLegacyFiles(now: Date) throws {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        for fileURL in legacyFiles(modifiedSince: modifiedSince) {
            try Task.checkCancellation()
            guard let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ]) else {
                continue
            }
            let signature = FileSignature(
                size: UInt64(max(0, values.fileSize ?? 0)),
                modificationDate: values.contentModificationDate
            )
            guard signature.size <= UInt64(configuration.maximumStructuredUsageFileBytes),
                  knownLegacySignatures[fileURL] != signature else {
                continue
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let event = try Self.event(
                fromJSONData: data,
                fallbackSessionIdentifier: fileURL.deletingLastPathComponent().lastPathComponent,
                fallbackMessageIdentifier: fileURL.deletingPathExtension().lastPathComponent
            )
            try repository.persistLocalEvents(
                event.map { [$0] } ?? [],
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_json",
                accuracy: accuracy
            )
            knownLegacySignatures[fileURL] = signature
        }
    }

    private func legacyFiles(modifiedSince: Date) -> [URL] {
        LocalUsageFileDiscovery.files(
            under: [messagesDirectory],
            extensions: ["json"],
            modifiedSince: modifiedSince,
            maximumFiles: configuration.maximumUsageSourceFiles
        ).filter { fileURL in
            fileURL.pathComponents.contains { $0.hasPrefix("ses_") }
        }
    }

    private static func event(fromDatabaseRow row: Row) -> LocalUsageEvent? {
        let rawData: String? = row["data"]
        guard let rawData, let data = rawData.data(using: .utf8) else { return nil }
        let sessionIdentifier: String? = row["session_id"]
        let messageIdentifier: String? = row["id"]
        return try? event(
            fromJSONData: data,
            fallbackSessionIdentifier: sessionIdentifier ?? "unknown",
            fallbackMessageIdentifier: messageIdentifier
        )
    }

    private static func event(
        fromJSONData data: Data,
        fallbackSessionIdentifier: String,
        fallbackMessageIdentifier: String?
    ) throws -> LocalUsageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = LocalUsageValue.dictionary(object),
              let tokens = LocalUsageValue.dictionary(record["tokens"]),
              let occurredAt = LocalUsageValue.date(
                LocalUsageValue.dictionary(record["time"])?["created"]
              ) else {
            return nil
        }
        let input = LocalUsageValue.count(tokens["input"])
        let output = LocalUsageValue.count(tokens["output"])
        let cached = LocalUsageValue.count(
            LocalUsageValue.dictionary(tokens["cache"])?["read"]
        )
        let reasoning = LocalUsageValue.count(tokens["reasoning"])
        guard input > 0 || output > 0 || cached > 0 || reasoning > 0 else { return nil }

        let sessionIdentifier = LocalUsageValue.string(record["sessionID"])
            ?? fallbackSessionIdentifier
        let model = LocalUsageValue.string(record["modelID"])
        guard model != nil else { return nil }
        let messageIdentifier = LocalUsageValue.string(record["id"])
            ?? fallbackMessageIdentifier
            ?? StableHash.string("\(sessionIdentifier):\(occurredAt.timeIntervalSince1970):\(model ?? "")")
        let rootPath = LocalUsageValue.string(
            LocalUsageValue.dictionary(record["path"])?["root"]
        )
        return LocalUsageEvent(
            idempotencyKey: "opencode:\(messageIdentifier)",
            sessionIdentifier: sessionIdentifier,
            model: model,
            projectLabel: rootPath.flatMap(lastPathComponent),
            occurredAt: occurredAt,
            counters: LocalUsageValue.counters(
                input: input,
                cachedInput: cached,
                cacheWrite: 0,
                output: output,
                reasoning: reasoning
            ),
            rawSchemaVersion: "opencode-message-tokens-v1"
        )
    }

    private var databaseURL: URL {
        dataRoot.appendingPathComponent("opencode.db", isDirectory: false)
    }

    private var messagesDirectory: URL {
        dataRoot.appendingPathComponent("storage/message", isDirectory: true)
    }

    private func databaseSignature() throws -> FileSignature {
        var totalSize: UInt64 = 0
        var latestModificationDate: Date?
        for fileURL in databaseFiles() where FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let (nextSize, overflow) = totalSize.addingReportingOverflow(
                UInt64(max(0, values.fileSize ?? 0))
            )
            totalSize = overflow ? UInt64.max : nextSize
            if let date = values.contentModificationDate,
               latestModificationDate == nil || date > latestModificationDate! {
                latestModificationDate = date
            }
        }
        return FileSignature(size: totalSize, modificationDate: latestModificationDate)
    }

    private func databaseFiles() -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: databaseURL.path + "-shm", isDirectory: false)
        ]
    }

    private static func lastPathComponent(_ rawPath: String) -> String? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.split(separator: "/").last.map(String.init)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

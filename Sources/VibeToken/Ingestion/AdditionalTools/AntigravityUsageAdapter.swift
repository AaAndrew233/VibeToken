import Foundation
import GRDB

actor AntigravityUsageAdapter: UsageSourceAdapter {
    nonisolated let sourceIdentifier = "antigravity"
    nonisolated let displayName = "Antigravity"
    nonisolated let accuracy = UsageAccuracy.exact

    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let homeDirectory: URL
    private let legacyClient: AntigravityLegacyClient
    private var knownSignatures: [URL: AntigravityFileSignature] = [:]
    private var lastLegacyAttemptAt: Date?

    init(
        configuration: AppConfiguration,
        repository: UsageRepository,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        legacyClient: AntigravityLegacyClient = AntigravityLegacyClient()
    ) {
        self.configuration = configuration
        self.repository = repository
        self.homeDirectory = homeDirectory
        self.legacyClient = legacyClient
    }

    func discover() async -> Bool {
        !usageFiles(now: Date()).isEmpty
    }

    func ingestRecentSessions(now: Date) async throws {
        let files = usageFiles(now: now)
        guard !files.isEmpty else { return }
        let databaseFiles = files.filter { $0.pathExtension.lowercased() == "db" }
        for fileURL in databaseFiles {
            try Task.checkCancellation()
            guard let signature = AntigravityFileSignature(fileURL: fileURL, includeSQLiteCompanions: true),
                  knownSignatures[fileURL] != signature else {
                continue
            }
            let events = try AntigravityDatabaseParser.events(
                databaseURL: fileURL,
                historyStart: historyStart(now: now)
            )
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_sqlite_protobuf",
                accuracy: accuracy,
                allowDecreasingTotals: true
            )
            knownSignatures[fileURL] = signature
            await Task.yield()
        }

        let legacyFiles = files.filter { $0.pathExtension.lowercased() == "pb" }
        let legacyChanged = legacyFiles.contains { fileURL in
            guard let signature = AntigravityFileSignature(
                fileURL: fileURL,
                includeSQLiteCompanions: false
            ) else {
                return false
            }
            return knownSignatures[fileURL] != signature
        }
        let retryDue = lastLegacyAttemptAt.map { now.timeIntervalSince($0) >= 5 * 60 } ?? true
        if !legacyFiles.isEmpty, legacyChanged || retryDue {
            lastLegacyAttemptAt = now
            let cascadeIDs = legacyFiles.map { $0.deletingPathExtension().lastPathComponent }
            let events = await legacyClient.events(
                cascadeIdentifiers: cascadeIDs,
                historyStart: historyStart(now: now)
            )
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_language_server",
                accuracy: accuracy,
                allowDecreasingTotals: true
            )
            for fileURL in legacyFiles {
                knownSignatures[fileURL] = AntigravityFileSignature(
                    fileURL: fileURL,
                    includeSQLiteCompanions: false
                )
            }
        }
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        let files = usageFiles(now: now)
        return UsageWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: conversationDirectories().filter(FileUsageParser.isDirectory)
        )
    }

    private func usageFiles(now: Date) -> [URL] {
        let modifiedSince = historyStart(now: now)
        return LocalUsageFileDiscovery.files(
            under: conversationDirectories(),
            extensions: ["db", "pb"],
            modifiedSince: modifiedSince,
            maximumFiles: configuration.maximumUsageSourceFiles
        ).filter { $0.lastPathComponent != "db.sqlite" }
    }

    private func conversationDirectories() -> [URL] {
        [
            homeDirectory.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true),
            homeDirectory.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        ]
    }

    private func historyStart(now: Date) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
    }
}

private struct AntigravityFileSignature: Equatable, Sendable {
    let size: UInt64
    let modificationDate: Date?

    init?(fileURL: URL, includeSQLiteCompanions: Bool) {
        let files = includeSQLiteCompanions
            ? [
                fileURL,
                URL(fileURLWithPath: fileURL.path + "-wal"),
                URL(fileURLWithPath: fileURL.path + "-shm")
            ]
            : [fileURL]
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var totalSize: UInt64 = 0
        var latestDate: Date?
        for candidate in files {
            guard let values = try? candidate.resourceValues(forKeys: [
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
}

enum AntigravityDatabaseParser {
    static func events(databaseURL: URL, historyStart: Date) throws -> [LocalUsageEvent] {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        let project = try queue.read { database -> String? in
            guard let data = try Data.fetchOne(
                database,
                sql: "SELECT data FROM trajectory_metadata_blob LIMIT 1"
            ),
            let workspace = try? ProtobufMessage(data: data).message(field: 1),
            let uri = workspace.string(field: 1) else {
                return nil
            }
            return FileUsageParser.projectName(uri)
        }
        let rows = try queue.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT idx, data FROM gen_metadata ORDER BY idx"
            )
        }
        let cascadeIdentifier = databaseURL.deletingPathExtension().lastPathComponent
        return rows.compactMap { row in
            let index: Int64 = row["idx"] ?? 0
            guard let data: Data = row["data"],
                  let usage = try? usageRecord(data: data),
                  usage.occurredAt >= historyStart else {
                return nil
            }
            return LocalUsageEvent(
                idempotencyKey: usage.responseIdentifier.map { "antigravity:\($0)" }
                    ?? "antigravity:\(cascadeIdentifier):\(index)",
                sessionIdentifier: cascadeIdentifier,
                model: usage.model,
                projectLabel: project,
                occurredAt: usage.occurredAt,
                counters: usage.counters,
                rawSchemaVersion: "antigravity-generator-metadata-v1"
            )
        }
    }

    private static func usageRecord(data: Data) throws -> AntigravityUsageRecord {
        let root = try ProtobufMessage(data: data)
        let chatModel = try root.message(field: 1)
        let usage = try chatModel.message(field: 4)
        let counters = LocalUsageValue.counters(
            input: Int64(clamping: usage.varint(field: 2) ?? 0),
            cachedInput: Int64(clamping: usage.varint(field: 5) ?? 0),
            cacheWrite: 0,
            output: Int64(clamping: usage.varint(field: 3) ?? 0),
            reasoning: Int64(clamping: usage.varint(field: 9) ?? 0)
        )
        guard counters.totalTokens > 0 else { throw ProtobufError.missingField }
        let startMetadata = try chatModel.message(field: 9)
        let timestamp = try startMetadata.message(field: 4)
        guard let seconds = timestamp.varint(field: 1), seconds > 0 else {
            throw ProtobufError.missingField
        }
        let rawModel = chatModel.string(field: 21)
            ?? chatModel.string(field: 19)
            ?? "unknown"
        return AntigravityUsageRecord(
            model: normalizedModel(rawModel),
            responseIdentifier: usage.string(field: 11)?.nilIfEmpty,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            counters: counters
        )
    }

    private static func normalizedModel(_ rawModel: String) -> String {
        switch rawModel {
        case "claude-opus-4-6-thinking": "claude-opus-4-6"
        case "claude-sonnet-4-6-thinking": "claude-sonnet-4-6"
        case "gemini-3.1-pro-high", "gemini-3.1-pro-low": "gemini-3.1-pro"
        case "gemini-3-pro-high", "gemini-3-pro-low": "gemini-3-pro"
        default: rawModel
        }
    }
}

private struct AntigravityUsageRecord {
    let model: String
    let responseIdentifier: String?
    let occurredAt: Date
    let counters: TokenUsageCounters
}

private enum ProtobufError: Error {
    case malformed
    case missingField
}

private struct ProtobufMessage {
    private enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private let fields: [Int: [Value]]

    init(data: Data) throws {
        var cursor = data.startIndex
        var parsed: [Int: [Value]] = [:]
        while cursor < data.endIndex {
            let tag = try Self.readVarint(data, cursor: &cursor)
            let field = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            guard field > 0 else { throw ProtobufError.malformed }
            let value: Value
            switch wireType {
            case 0:
                value = .varint(try Self.readVarint(data, cursor: &cursor))
            case 1:
                guard data.distance(from: cursor, to: data.endIndex) >= 8 else {
                    throw ProtobufError.malformed
                }
                cursor = data.index(cursor, offsetBy: 8)
                continue
            case 2:
                let length = try Self.readVarint(data, cursor: &cursor)
                guard length <= UInt64(Int.max) else { throw ProtobufError.malformed }
                let count = Int(length)
                guard data.distance(from: cursor, to: data.endIndex) >= count else {
                    throw ProtobufError.malformed
                }
                let end = data.index(cursor, offsetBy: count)
                value = .bytes(Data(data[cursor..<end]))
                cursor = end
            case 5:
                guard data.distance(from: cursor, to: data.endIndex) >= 4 else {
                    throw ProtobufError.malformed
                }
                cursor = data.index(cursor, offsetBy: 4)
                continue
            default:
                throw ProtobufError.malformed
            }
            parsed[field, default: []].append(value)
        }
        fields = parsed
    }

    func varint(field: Int) -> UInt64? {
        fields[field]?.compactMap { value in
            if case let .varint(number) = value { return number }
            return nil
        }.first
    }

    func string(field: Int) -> String? {
        fields[field]?.compactMap { value -> String? in
            guard case let .bytes(data) = value else { return nil }
            return String(data: data, encoding: .utf8)
        }.first
    }

    func message(field: Int) throws -> ProtobufMessage {
        guard let data = fields[field]?.compactMap({ value in
            if case let .bytes(data) = value { return data }
            return nil
        }).first else {
            throw ProtobufError.missingField
        }
        return try ProtobufMessage(data: data)
    }

    private static func readVarint(_ data: Data, cursor: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < data.endIndex, shift < 64 {
            let byte = data[cursor]
            cursor = data.index(after: cursor)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtobufError.malformed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

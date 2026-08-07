import Foundation

actor CodexUsageAdapter: UsageSourceAdapter {
    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date?
    }

    nonisolated let sourceIdentifier = "codex"
    nonisolated let displayName = "Codex"
    nonisolated let accuracy = UsageAccuracy.exact

    private let configuration: AppConfiguration
    private var codexHomes: [URL]
    private let parser = CodexTokenEventParser()
    private let repository: UsageRepository
    private var cachedLatestURL: URL?
    private var cachedLatestFileSize: Int64?
    private var cachedLatestModificationDate: Date?
    private var cachedLatestSnapshot: TokenUsageSnapshot?
    private var knownFileSignatures: [URL: FileSignature] = [:]

    init(configuration: AppConfiguration, repository: UsageRepository) {
        self.configuration = configuration
        codexHomes = Self.uniqueURLs([configuration.codexHome] + configuration.additionalCodexHomes)
        self.repository = repository
    }

    func discover() async -> Bool {
        dataRoots().contains(where: Self.isDirectory)
    }

    func currentSnapshot() async throws -> TokenUsageSnapshot? {
        guard await discover(), let fileURL = try latestSessionFile() else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(values.fileSize ?? 0)
        let modificationDate = values.contentModificationDate

        if fileURL == cachedLatestURL,
           fileSize == cachedLatestFileSize,
           modificationDate == cachedLatestModificationDate {
            return cachedLatestSnapshot
        }

        let snapshot = try parser.parseLatestUsage(
            in: fileURL,
            maximumTailBytes: configuration.maximumTailBytes
        )
        cachedLatestURL = fileURL
        cachedLatestFileSize = fileSize
        cachedLatestModificationDate = modificationDate
        cachedLatestSnapshot = snapshot
        return snapshot
    }

    func ingestRecentSessions() async throws {
        try await ingestRecentSessions(now: Date())
    }

    func ingestRecentSessions(now: Date = Date()) async throws {
        guard await discover() else { return }
        for fileURL in try recentSessionFiles(now: now) {
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ])
            let fileSize = UInt64(max(0, values.fileSize ?? 0))
            let signature = FileSignature(
                size: fileSize,
                modificationDate: values.contentModificationDate
            )
            if knownFileSignatures[fileURL] == signature {
                continue
            }
            try autoreleasepool {
                try ingest(
                    fileURL: fileURL,
                    fileSize: fileSize,
                    modificationDate: values.contentModificationDate
                )
            }
            knownFileSignatures[fileURL] = signature
            await Task.yield()
        }
    }

    func aggregate(range: UsageTimeRange, now: Date = Date()) throws -> UsageAggregation {
        try repository.aggregate(
            source: sourceIdentifier,
            from: range.startDate(now: now),
            through: now
        )
    }

    func trend(
        range: UsageTimeRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> UsageTrendSeries {
        let granularity = UsageTrendGranularity.forRange(range)
        let intervals = granularity.intervals(
            from: range.startDate(now: now, calendar: calendar),
            through: now,
            calendar: calendar
        )
        return try repository.trend(
            source: sourceIdentifier,
            intervals: intervals,
            granularity: granularity
        )
    }

    func watchTargets(now: Date = Date()) throws -> CodexWatchTargets {
        let calendar = Calendar.current
        let todayDirectories = sessionRoots().map {
            directory(for: now, sessionsRoot: $0, calendar: calendar)
        }
        let directories = todayDirectories + archiveRoots().filter(Self.isDirectory)
        let files = try directories.flatMap { try jsonlFiles(in: $0) }
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
        return CodexWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: directories
        )
    }

    private func ingest(
        fileURL: URL,
        fileSize: UInt64,
        modificationDate: Date?
    ) throws {
        let fileIdentity = CodexTokenEventParser.sessionIdentifier(for: fileURL)
        let storedState = try repository.checkpoint(fileIdentity: fileIdentity) ?? .initial
        let initialState = storedState.byteOffset <= fileSize ? storedState : .initial
        guard initialState.byteOffset != fileSize else { return }

        let batch = try parser.parseIncrementalUsage(
            in: fileURL,
            sessionIdentifier: fileIdentity,
            initialState: initialState,
            chunkBytes: configuration.ingestionChunkBytes,
            maximumLineBytes: configuration.maximumJSONLineBytes
        )
        try repository.persist(
            batch: batch,
            fileIdentity: fileIdentity,
            canonicalPathHash: CodexTokenEventParser.pathHash(for: fileURL),
            sourceDisplayName: displayName
        )
        if let latestSnapshot = batch.latestSnapshot {
            cachedLatestURL = fileURL
            cachedLatestFileSize = Int64(clamping: fileSize)
            cachedLatestModificationDate = modificationDate
            cachedLatestSnapshot = latestSnapshot
        }
    }

    private func latestSessionFile() throws -> URL? {
        let todayFiles = try sessionRoots().flatMap {
            try jsonlFiles(in: directory(for: Date(), sessionsRoot: $0, calendar: .current))
        }
        if !todayFiles.isEmpty {
            return todayFiles.max { modificationDate(for: $0) < modificationDate(for: $1) }
        }
        return try recentSessionFiles(now: Date()).max {
            modificationDate(for: $0) < modificationDate(for: $1)
        }
    }

    private func recentSessionFiles(now: Date) throws -> [URL] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now.addingTimeInterval(
            -TimeInterval(configuration.historyLookbackDays) * 24 * 60 * 60
        ))
        let end = calendar.startOfDay(for: now)
        var current = start
        var files: [URL] = []

        while current <= end {
            for sessionsRoot in sessionRoots() {
                files.append(contentsOf: try jsonlFiles(
                    in: directory(for: current, sessionsRoot: sessionsRoot, calendar: calendar)
                ))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        files.append(contentsOf: LocalUsageFileDiscovery.files(
            under: archiveRoots(),
            extensions: ["jsonl"],
            modifiedSince: start,
            maximumFiles: configuration.maximumUsageSourceFiles
        ))
        return files.sorted { left, right in
            modificationDate(for: left) < modificationDate(for: right)
        }
    }

    private func directory(for date: Date, sessionsRoot: URL, calendar: Calendar) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return sessionsRoot
            .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private func jsonlFiles(in directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" }
    }

    private func sessionRoots() -> [URL] {
        codexHomes.map { $0.appendingPathComponent("sessions", isDirectory: true) }
    }

    private func archiveRoots() -> [URL] {
        codexHomes.map { $0.appendingPathComponent("archived_sessions", isDirectory: true) }
    }

    private func dataRoots() -> [URL] {
        sessionRoots() + archiveRoots()
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter {
            seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

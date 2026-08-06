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
    private let sessionsRoot: URL
    private let parser = CodexTokenEventParser()
    private let repository: UsageRepository
    private var cachedLatestURL: URL?
    private var cachedLatestFileSize: Int64?
    private var cachedLatestModificationDate: Date?
    private var cachedLatestSnapshot: TokenUsageSnapshot?
    private var knownFileSignatures: [URL: FileSignature] = [:]

    init(configuration: AppConfiguration, repository: UsageRepository) {
        self.configuration = configuration
        sessionsRoot = configuration.codexHome.appendingPathComponent("sessions", isDirectory: true)
        self.repository = repository
    }

    func discover() async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
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
        let todayDirectory = directory(for: now, calendar: calendar)
        let files = try jsonlFiles(in: todayDirectory)
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
        return CodexWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: [todayDirectory]
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
        let todayFiles = try jsonlFiles(in: directory(for: Date(), calendar: .current))
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
            files.append(contentsOf: try jsonlFiles(in: directory(for: current, calendar: calendar)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return files.sorted { left, right in
            modificationDate(for: left) < modificationDate(for: right)
        }
    }

    private func directory(for date: Date, calendar: Calendar) -> URL {
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
}

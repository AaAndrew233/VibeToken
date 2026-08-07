import Foundation

actor UsageIngestionCoordinator {
    private let sources: [any UsageSourceAdapter]
    private let repository: UsageRepository
    private let maximumWatchFiles: Int

    init(
        sources: [any UsageSourceAdapter],
        repository: UsageRepository,
        maximumWatchFiles: Int
    ) {
        self.sources = sources
        self.repository = repository
        self.maximumWatchFiles = max(1, maximumWatchFiles)
    }

    func ingestRecentSessions(now: Date = Date()) async throws {
        var firstError: Error?
        var discoveredSourceCount = 0
        var successfulSourceCount = 0
        for source in sources {
            do {
                guard await source.discover() else { continue }
                discoveredSourceCount += 1
                try await source.ingestRecentSessions(now: now)
                successfulSourceCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                PrivacyLog.ingestion.error(
                    "Usage source refresh failed: \(source.sourceIdentifier, privacy: .public), \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }

        if discoveredSourceCount > 0, successfulSourceCount == 0, let firstError {
            throw firstError
        }
    }

    func currentSnapshot() throws -> TokenUsageSnapshot? {
        try repository.latestConversationSnapshot()
    }

    func aggregate(range: UsageTimeRange, now: Date = Date()) throws -> UsageAggregation {
        try repository.aggregate(
            source: nil,
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
            source: nil,
            intervals: intervals,
            granularity: granularity
        )
    }

    func watchTargets(now: Date = Date()) async -> UsageWatchTargets {
        var files = Set<URL>()
        var directories = Set<URL>()
        for source in sources {
            do {
                guard await source.discover() else { continue }
                let targets = try await source.watchTargets(now: now)
                files.formUnion(targets.fileURLs)
                directories.formUnion(targets.directoryURLs)
            } catch {
                PrivacyLog.ingestion.error(
                    "Usage watch setup failed: \(source.sourceIdentifier, privacy: .public), \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        let sortedFiles = files.sorted { modificationDate(for: $0) > modificationDate(for: $1) }
        return UsageWatchTargets(
            fileURLs: Array(sortedFiles.prefix(maximumWatchFiles)),
            directoryURLs: Array(directories)
        )
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}

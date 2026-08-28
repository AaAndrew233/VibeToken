import Foundation

actor UsageIngestionCoordinator {
    private struct DiscoveryCacheEntry: Sendable {
        let isAvailable: Bool
        let checkedAt: Date
    }

    private let sources: [any UsageSourceAdapter]
    private let repository: UsageRepository
    private let maximumWatchFiles: Int
    private let sourceDiscoveryCacheInterval: TimeInterval
    private let watchTargetCacheInterval: TimeInterval
    private var discoveryCache: [String: DiscoveryCacheEntry] = [:]
    private var cachedWatchTargets: UsageWatchTargets?
    private var cachedWatchTargetsAt: Date?

    init(
        sources: [any UsageSourceAdapter],
        repository: UsageRepository,
        maximumWatchFiles: Int,
        sourceDiscoveryCacheInterval: TimeInterval = 60,
        watchTargetCacheInterval: TimeInterval = 5 * 60
    ) {
        self.sources = sources
        self.repository = repository
        self.maximumWatchFiles = max(1, maximumWatchFiles)
        self.sourceDiscoveryCacheInterval = max(0, sourceDiscoveryCacheInterval)
        self.watchTargetCacheInterval = max(0, watchTargetCacheInterval)
    }

    func ingestRecentSessions(now: Date = Date()) async throws {
        var firstError: Error?
        var discoveredSourceCount = 0
        var successfulSourceCount = 0
        for source in sources {
            do {
                guard await isSourceAvailable(source, now: now) else { continue }
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
        if let cachedWatchTargets,
           let cachedWatchTargetsAt,
           isFresh(cachedWatchTargetsAt, at: now, interval: watchTargetCacheInterval) {
            return cachedWatchTargets
        }

        var files = Set<URL>()
        var directories = Set<URL>()
        var hadError = false
        for source in sources {
            do {
                guard await isSourceAvailable(source, now: now) else { continue }
                let targets = try await source.watchTargets(now: now)
                files.formUnion(targets.fileURLs)
                directories.formUnion(targets.directoryURLs)
            } catch {
                hadError = true
                PrivacyLog.ingestion.error(
                    "Usage watch setup failed: \(source.sourceIdentifier, privacy: .public), \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        let sortedFiles = files.sorted { modificationDate(for: $0) > modificationDate(for: $1) }
        let targets = UsageWatchTargets(
            fileURLs: Array(sortedFiles.prefix(maximumWatchFiles)),
            directoryURLs: Array(directories)
        )
        if !hadError {
            cachedWatchTargets = targets
            cachedWatchTargetsAt = now
        }
        return targets
    }

    private func isSourceAvailable(
        _ source: any UsageSourceAdapter,
        now: Date
    ) async -> Bool {
        let previous = discoveryCache[source.sourceIdentifier]
        if let cached = previous,
           isFresh(cached.checkedAt, at: now, interval: sourceDiscoveryCacheInterval) {
            return cached.isAvailable
        }
        let isAvailable = await source.discover()
        discoveryCache[source.sourceIdentifier] = DiscoveryCacheEntry(
            isAvailable: isAvailable,
            checkedAt: now
        )
        if let previous, previous.isAvailable != isAvailable {
            cachedWatchTargets = nil
            cachedWatchTargetsAt = nil
        }
        return isAvailable
    }

    private func isFresh(_ cachedAt: Date, at now: Date, interval: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(cachedAt)
        return age >= 0 && age < interval
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}

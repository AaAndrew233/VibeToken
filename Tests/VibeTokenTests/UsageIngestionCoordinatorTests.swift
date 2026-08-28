import Foundation
import XCTest
@testable import VibeToken

final class UsageIngestionCoordinatorTests: XCTestCase {
    func testOneBrokenSourceDoesNotPreventHealthySourceAggregation() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let now = Date()
        let coordinator = UsageIngestionCoordinator(
            sources: [
                FailingUsageSourceAdapter(),
                FixtureUsageSourceAdapter(repository: repository, occurredAt: now)
            ],
            repository: repository,
            maximumWatchFiles: 10
        )

        try await coordinator.ingestRecentSessions(now: now)
        let aggregate = try await coordinator.aggregate(range: .hours24, now: now)

        XCTAssertEqual(aggregate.snapshot?.totalTokens, 42)
        XCTAssertEqual(aggregate.sourceBreakdowns.map(\.displayName), ["Fixture Tool"])
        let currentSnapshot = try await coordinator.currentSnapshot()
        XCTAssertEqual(currentSnapshot?.source, "fixture")
    }

    func testThrowsWhenEveryDiscoveredSourceFails() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let coordinator = UsageIngestionCoordinator(
            sources: [FailingUsageSourceAdapter(), FailingUsageSourceAdapter()],
            repository: UsageRepository(database: database),
            maximumWatchFiles: 10
        )

        do {
            try await coordinator.ingestRecentSessions(now: Date())
            XCTFail("Expected all-source failure to be surfaced")
        } catch TestSourceError.expected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnavailableSourceDiscoveryIsCachedUntilExpiry() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let source = CountingUsageSourceAdapter(isAvailable: false)
        let coordinator = UsageIngestionCoordinator(
            sources: [source],
            repository: UsageRepository(database: database),
            maximumWatchFiles: 10,
            sourceDiscoveryCacheInterval: 60
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await coordinator.ingestRecentSessions(now: now)
        try await coordinator.ingestRecentSessions(now: now.addingTimeInterval(30))
        let cachedDiscoveryCount = await source.discoveryCount
        XCTAssertEqual(cachedDiscoveryCount, 1)

        try await coordinator.ingestRecentSessions(now: now.addingTimeInterval(60))
        let expiredDiscoveryCount = await source.discoveryCount
        let ingestionCount = await source.ingestionCount
        XCTAssertEqual(expiredDiscoveryCount, 2)
        XCTAssertEqual(ingestionCount, 0)
    }

    func testWatchTargetsAreCachedUntilExpiry() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let source = CountingUsageSourceAdapter(isAvailable: true)
        let coordinator = UsageIngestionCoordinator(
            sources: [source],
            repository: UsageRepository(database: database),
            maximumWatchFiles: 10,
            sourceDiscoveryCacheInterval: 60,
            watchTargetCacheInterval: 300
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await coordinator.watchTargets(now: now)
        _ = await coordinator.watchTargets(now: now.addingTimeInterval(299))
        let cachedWatchTargetCount = await source.watchTargetCount
        XCTAssertEqual(cachedWatchTargetCount, 1)

        _ = await coordinator.watchTargets(now: now.addingTimeInterval(300))
        let expiredWatchTargetCount = await source.watchTargetCount
        XCTAssertEqual(expiredWatchTargetCount, 2)
    }

    func testFailedWatchTargetCollectionIsRetriedWithoutCaching() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let source = TransientWatchFailureUsageSourceAdapter()
        let coordinator = UsageIngestionCoordinator(
            sources: [source],
            repository: UsageRepository(database: database),
            maximumWatchFiles: 10,
            watchTargetCacheInterval: 300
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await coordinator.watchTargets(now: now)
        _ = await coordinator.watchTargets(now: now.addingTimeInterval(1))

        let watchTargetCount = await source.watchTargetCount
        XCTAssertEqual(watchTargetCount, 2)
    }

    func testSourceAvailabilityChangeInvalidatesWatchTargetCache() async throws {
        let database = try VibeTokenDatabase.inMemory()
        let source = CountingUsageSourceAdapter(isAvailable: false)
        let coordinator = UsageIngestionCoordinator(
            sources: [source],
            repository: UsageRepository(database: database),
            maximumWatchFiles: 10,
            sourceDiscoveryCacheInterval: 60,
            watchTargetCacheInterval: 300
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await coordinator.watchTargets(now: now)
        await source.setAvailable(true)
        try await coordinator.ingestRecentSessions(now: now.addingTimeInterval(60))
        _ = await coordinator.watchTargets(now: now.addingTimeInterval(61))

        let watchTargetCount = await source.watchTargetCount
        XCTAssertEqual(watchTargetCount, 1)
    }
}

private actor FailingUsageSourceAdapter: UsageSourceAdapter {
    nonisolated let sourceIdentifier = "broken"
    nonisolated let displayName = "Broken"
    nonisolated let accuracy = UsageAccuracy.exact

    func discover() async -> Bool { true }
    func ingestRecentSessions(now: Date) async throws { throw TestSourceError.expected }
    func watchTargets(now: Date) async throws -> UsageWatchTargets { .empty }
}

private actor FixtureUsageSourceAdapter: UsageSourceAdapter {
    nonisolated let sourceIdentifier = "fixture"
    nonisolated let displayName = "Fixture Tool"
    nonisolated let accuracy = UsageAccuracy.exact

    private let repository: UsageRepository
    private let occurredAt: Date

    init(repository: UsageRepository, occurredAt: Date) {
        self.repository = repository
        self.occurredAt = occurredAt
    }

    func discover() async -> Bool { true }

    func ingestRecentSessions(now: Date) async throws {
        try repository.persistLocalEvents(
            [
                LocalUsageEvent(
                    idempotencyKey: "fixture:event",
                    sessionIdentifier: "session",
                    model: "fixture-model",
                    projectLabel: "Fixture",
                    occurredAt: occurredAt,
                    counters: LocalUsageValue.counters(
                        input: 42,
                        cachedInput: 0,
                        cacheWrite: 0,
                        output: 0,
                        reasoning: 0
                    ),
                    rawSchemaVersion: "fixture-v1"
                )
            ],
            sourceIdentifier: sourceIdentifier,
            sourceDisplayName: displayName,
            sourceKind: "fixture",
            accuracy: accuracy
        )
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets { .empty }
}

private actor CountingUsageSourceAdapter: UsageSourceAdapter {
    nonisolated let sourceIdentifier = "counting"
    nonisolated let displayName = "Counting"
    nonisolated let accuracy = UsageAccuracy.exact

    private(set) var discoveryCount = 0
    private(set) var ingestionCount = 0
    private(set) var watchTargetCount = 0
    private var isAvailable: Bool

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func discover() async -> Bool {
        discoveryCount += 1
        return isAvailable
    }

    func setAvailable(_ isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func ingestRecentSessions(now _: Date) async throws {
        ingestionCount += 1
    }

    func watchTargets(now _: Date) async throws -> UsageWatchTargets {
        watchTargetCount += 1
        return .empty
    }
}

private actor TransientWatchFailureUsageSourceAdapter: UsageSourceAdapter {
    nonisolated let sourceIdentifier = "transient-watch-failure"
    nonisolated let displayName = "Transient Watch Failure"
    nonisolated let accuracy = UsageAccuracy.exact

    private(set) var watchTargetCount = 0

    func discover() async -> Bool { true }
    func ingestRecentSessions(now _: Date) async throws {}

    func watchTargets(now _: Date) async throws -> UsageWatchTargets {
        watchTargetCount += 1
        if watchTargetCount == 1 {
            throw TestSourceError.expected
        }
        return .empty
    }
}

private enum TestSourceError: Error {
    case expected
}

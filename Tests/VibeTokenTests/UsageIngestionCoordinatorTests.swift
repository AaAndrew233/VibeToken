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

private enum TestSourceError: Error {
    case expected
}

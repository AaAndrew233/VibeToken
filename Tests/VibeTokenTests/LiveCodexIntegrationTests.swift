import Foundation
import XCTest
@testable import VibeToken

final class LiveCodexIntegrationTests: XCTestCase {
    func testReadsCurrentCodexSnapshotWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VIBETOKEN_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set VIBETOKEN_LIVE_TEST=1 to run the local read-only probe")
        }

        let configuration = AppConfiguration.live()
        let database = try VibeTokenDatabase.inMemory()
        let adapter = CodexUsageAdapter(
            configuration: configuration,
            repository: UsageRepository(database: database)
        )
        let snapshot = try await adapter.currentSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertGreaterThan(snapshot?.totalTokens ?? 0, 0)
        XCTAssertEqual(snapshot?.source, "codex")
        XCTAssertEqual(snapshot?.accuracy, .exact)
    }

    func testIndexesRecentCodexSessionsWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VIBETOKEN_LIVE_AGGREGATE_TEST"] == "1" else {
            throw XCTSkip("Set VIBETOKEN_LIVE_AGGREGATE_TEST=1 to run the local aggregate probe")
        }

        let database = try VibeTokenDatabase.inMemory()
        let adapter = CodexUsageAdapter(
            configuration: .live(),
            repository: UsageRepository(database: database)
        )
        let now = Date()
        try await adapter.ingestRecentSessions(now: now)
        let aggregate = try await adapter.aggregate(range: .days30, now: now)

        XCTAssertGreaterThan(aggregate.snapshot?.totalTokens ?? 0, 0)
        XCTAssertGreaterThan(aggregate.sessionCount, 1)
        XCTAssertFalse(aggregate.modelSnapshots.isEmpty)
    }
}

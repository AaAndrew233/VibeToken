import Foundation
import XCTest
@testable import VibeToken

final class LiveClaudeCodeIntegrationTests: XCTestCase {
    func testIndexesLocalClaudeCodeUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VIBETOKEN_LIVE_CLAUDE_TEST"] == "1" else {
            throw XCTSkip("Set VIBETOKEN_LIVE_CLAUDE_TEST=1 to run the local read-only Claude probe")
        }
        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let latestModificationDate = try XCTUnwrap(latestJSONLModificationDate(
            under: claudeRoot.appendingPathComponent("projects", isDirectory: true)
        ))
        let probeNow = latestModificationDate.addingTimeInterval(1)
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = ClaudeCodeUsageAdapter(
            configuration: AppConfiguration.live(),
            repository: repository,
            rootsOverride: [claudeRoot]
        )

        let discovered = await adapter.discover()
        XCTAssertTrue(discovered)
        try await adapter.ingestRecentSessions(now: probeNow)
        let aggregate = try repository.aggregate(
            source: "claude-code",
            from: probeNow.addingTimeInterval(-30 * 24 * 60 * 60),
            through: probeNow.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertGreaterThan(aggregate.snapshot?.totalTokens ?? 0, 0)
    }

    private func latestJSONLModificationDate(under directory: URL) -> Date? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }
        var latest: Date?
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey
            ]), values.isRegularFile == true,
              let modificationDate = values.contentModificationDate else {
                continue
            }
            if latest == nil || modificationDate > latest! {
                latest = modificationDate
            }
        }
        return latest
    }
}

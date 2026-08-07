import Foundation
@testable import VibeToken

func makeTestConfiguration(dataRoot: URL) -> AppConfiguration {
    AppConfiguration(
        codexHome: dataRoot.appendingPathComponent(".codex", isDirectory: true),
        applicationSupportDirectory: dataRoot,
        refreshInterval: .seconds(5),
        fileEventDebounceMilliseconds: 100,
        maximumTailBytes: 1_024 * 1_024,
        ingestionChunkBytes: 4 * 1_024,
        maximumJSONLineBytes: 1_024 * 1_024,
        historyLookbackDays: 30,
        maximumWatchedSessionFiles: 64,
        maximumUsageSourceFiles: 1_000,
        maximumStructuredUsageFileBytes: 8 * 1_024 * 1_024,
        additionalCodexHomes: []
    )
}

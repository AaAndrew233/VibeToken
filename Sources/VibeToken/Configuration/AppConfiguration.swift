import Foundation

struct AppConfiguration: Sendable {
    let codexHome: URL
    let applicationSupportDirectory: URL
    let refreshInterval: Duration
    let fileEventDebounceMilliseconds: Int
    let maximumTailBytes: Int
    let ingestionChunkBytes: Int
    let maximumJSONLineBytes: Int
    let historyLookbackDays: Int
    let maximumWatchedSessionFiles: Int
    let sub2APIRequestTimeoutSeconds: TimeInterval = 15
    let sub2APIPageSize: Int = 100
    let sub2APIMaximumPages: Int = 100
    let sub2APISnapshotStaleSeconds: TimeInterval = 15 * 60
    let sub2APIMinimumRefreshSeconds: TimeInterval = 30

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfiguration {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configuredCodexHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let codexHome: URL
        if let configuredCodexHome, !configuredCodexHome.isEmpty {
            codexHome = URL(fileURLWithPath: configuredCodexHome, isDirectory: true)
        } else {
            codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }

        return AppConfiguration(
            codexHome: codexHome,
            applicationSupportDirectory: defaultApplicationSupportDirectory,
            refreshInterval: .seconds(5),
            fileEventDebounceMilliseconds: 100,
            maximumTailBytes: 4 * 1_024 * 1_024,
            ingestionChunkBytes: 512 * 1_024,
            maximumJSONLineBytes: 8 * 1_024 * 1_024,
            historyLookbackDays: 30,
            maximumWatchedSessionFiles: 64
        )
    }

    static var defaultApplicationSupportDirectory: URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseDirectory.appendingPathComponent("VibeToken", isDirectory: true)
    }
}

import Foundation

struct AppConfiguration: Sendable {
    static let codexHomeOverrideKey = "codexHomePath"

    let codexHome: URL
    let applicationSupportDirectory: URL
    let refreshInterval: Duration
    let fileEventDebounceMilliseconds: Int
    let maximumTailBytes: Int
    let ingestionChunkBytes: Int
    let maximumJSONLineBytes: Int
    let historyLookbackDays: Int
    let maximumWatchedSessionFiles: Int
    let maximumUsageSourceFiles: Int
    let maximumStructuredUsageFileBytes: Int
    let usageDatabasePageSize: Int = 500
    let additionalCodexHomes: [URL]
    let sub2APIRequestTimeoutSeconds: TimeInterval = 15
    let sub2APIPageSize: Int = 100
    let sub2APIMaximumPages: Int = 100
    let sub2APISnapshotStaleSeconds: TimeInterval = 8 * 60 * 60
    let sub2APIMinimumRefreshSeconds: TimeInterval = 30
    let sub2APIPollingInterval: Duration = .seconds(30)
    let sub2APIUsageRefreshIntervalSeconds: TimeInterval = 30 * 60

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> AppConfiguration {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configuredCodexHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let savedCodexHome = userDefaults.string(forKey: codexHomeOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let defaultCodexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let codexHome: URL
        if let configuredCodexHome, !configuredCodexHome.isEmpty {
            codexHome = URL(fileURLWithPath: configuredCodexHome, isDirectory: true)
        } else {
            codexHome = defaultCodexHome
        }

        var additionalCodexHomes: [URL] = [defaultCodexHome]
        if let savedCodexHome, !savedCodexHome.isEmpty {
            additionalCodexHomes.append(URL(fileURLWithPath: savedCodexHome, isDirectory: true))
        }
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            additionalCodexHomes.append(contentsOf: entries.filter {
                $0.lastPathComponent.hasPrefix(".codex-")
            })
        }
        var seenCodexHomes = Set<String>()
        additionalCodexHomes = additionalCodexHomes.filter {
            let path = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return path != codexHome.standardizedFileURL.resolvingSymlinksInPath().path
                && seenCodexHomes.insert(path).inserted
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
            maximumWatchedSessionFiles: 256,
            maximumUsageSourceFiles: 10_000,
            maximumStructuredUsageFileBytes: 64 * 1_024 * 1_024,
            additionalCodexHomes: additionalCodexHomes
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

import Foundation

protocol UsageSourceAdapter: Sendable {
    var sourceIdentifier: String { get }
    var displayName: String { get }
    var accuracy: UsageAccuracy { get }

    func discover() async -> Bool
    func ingestRecentSessions(now: Date) async throws
    func watchTargets(now: Date) async throws -> UsageWatchTargets
}

struct UsageWatchTargets: Sendable {
    let fileURLs: [URL]
    let directoryURLs: [URL]

    static let empty = UsageWatchTargets(fileURLs: [], directoryURLs: [])
}

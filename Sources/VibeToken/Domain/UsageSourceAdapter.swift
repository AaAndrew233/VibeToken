import Foundation

protocol UsageSourceAdapter: Sendable {
    var sourceIdentifier: String { get }
    var displayName: String { get }
    var accuracy: UsageAccuracy { get }

    func discover() async -> Bool
    func currentSnapshot() async throws -> TokenUsageSnapshot?
}

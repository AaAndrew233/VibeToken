import Foundation

struct LocalUsageEvent: Equatable, Sendable {
    let idempotencyKey: String
    let sessionIdentifier: String
    let model: String?
    let projectLabel: String?
    let occurredAt: Date
    let counters: TokenUsageCounters
    let rawSchemaVersion: String
}

struct LocalFileCheckpoint: Equatable, Sendable {
    let byteOffset: UInt64
}

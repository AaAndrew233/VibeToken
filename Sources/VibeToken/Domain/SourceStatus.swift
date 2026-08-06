import Foundation

enum SourceStatus: Equatable, Sendable {
    case loading
    case online
    case noData
    case unavailable
    case failed(String)
}

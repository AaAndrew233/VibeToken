import Foundation

enum UsageAccuracy: String, Codable, Sendable {
    case exact
    case derived
    case estimated
    case credits
}

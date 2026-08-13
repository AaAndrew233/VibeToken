import Foundation

struct AppUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicKey: String

    init?(infoDictionary: [String: Any]?) {
        guard
            let feedURLString = infoDictionary?["SUFeedURL"] as? String,
            let feedURL = URL(string: feedURLString),
            feedURL.scheme?.lowercased() == "https",
            feedURL.host != nil,
            let publicKey = infoDictionary?["SUPublicEDKey"] as? String,
            let publicKeyData = Data(base64Encoded: publicKey),
            publicKeyData.count == 32
        else {
            return nil
        }

        self.feedURL = feedURL
        self.publicKey = publicKey
    }
}

import XCTest
@testable import VibeToken

final class AppUpdateConfigurationTests: XCTestCase {
    private let publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    func testAcceptsHTTPSFeedWithPublicKey() throws {
        let configuration = try XCTUnwrap(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://updates.example.com/appcast.xml",
            "SUPublicEDKey": publicKey
        ]))

        XCTAssertEqual(configuration.feedURL.absoluteString, "https://updates.example.com/appcast.xml")
        XCTAssertEqual(configuration.publicKey, publicKey)
    }

    func testRejectsMissingPartialOrInsecureConfiguration() {
        XCTAssertNil(AppUpdateConfiguration(infoDictionary: nil))
        XCTAssertNil(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://updates.example.com/appcast.xml"
        ]))
        XCTAssertNil(AppUpdateConfiguration(infoDictionary: [
            "SUPublicEDKey": publicKey
        ]))
        XCTAssertNil(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "http://updates.example.com/appcast.xml",
            "SUPublicEDKey": publicKey
        ]))
        XCTAssertNil(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://updates.example.com/appcast.xml",
            "SUPublicEDKey": "not-a-valid-key"
        ]))
    }
}

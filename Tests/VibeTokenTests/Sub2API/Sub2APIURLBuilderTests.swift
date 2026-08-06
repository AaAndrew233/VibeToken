import XCTest
@testable import VibeToken

final class Sub2APIURLBuilderTests: XCTestCase {
    func testNormalizesServerRootAndExistingAPIBase() throws {
        XCTAssertEqual(
            try Sub2APIURLBuilder.normalize("https://relay.example.com").absoluteString,
            "https://relay.example.com/api/v1"
        )
        XCTAssertEqual(
            try Sub2APIURLBuilder.normalize("https://relay.example.com/api/v1/").absoluteString,
            "https://relay.example.com/api/v1"
        )
    }

    func testRejectsRemoteHTTPEmbeddedCredentialsAndUnexpectedPath() {
        XCTAssertThrowsError(try Sub2APIURLBuilder.normalize("http://relay.example.com")) {
            XCTAssertEqual($0 as? Sub2APIError, .insecureServerURL)
        }
        XCTAssertThrowsError(try Sub2APIURLBuilder.normalize("https://user:secret@relay.example.com"))
        XCTAssertThrowsError(try Sub2APIURLBuilder.normalize("https://relay.example.com/admin"))
    }

    func testAllowsHTTPForLocalDevelopmentOnly() throws {
        XCTAssertEqual(
            try Sub2APIURLBuilder.normalize("http://127.0.0.1:8080").absoluteString,
            "http://127.0.0.1:8080/api/v1"
        )
    }
}

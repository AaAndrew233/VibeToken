import Foundation
import XCTest
@testable import VibeToken

final class DockIconModeTests: XCTestCase {
    func testUnsetAndInvalidValuesDefaultToAlways() throws {
        let suiteName = "DockIconModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DockIconMode.load(from: defaults), .always)

        defaults.set("unexpected", forKey: DockIconMode.userDefaultsKey)
        XCTAssertEqual(DockIconMode.load(from: defaults), .always)
    }

    func testLoadsMenuBarOnlyValue() throws {
        let suiteName = "DockIconModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(DockIconMode.menuBarOnly.rawValue, forKey: DockIconMode.userDefaultsKey)

        XCTAssertEqual(DockIconMode.load(from: defaults), .menuBarOnly)
    }
}

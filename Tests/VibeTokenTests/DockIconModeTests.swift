import Foundation
import ServiceManagement
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

    func testBothDockModesSurviveReopeningPreferences() throws {
        let suiteName = "DockIconPersistenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for mode in DockIconMode.allCases {
            mode.save(to: defaults)
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            XCTAssertEqual(DockIconMode.load(from: reopenedDefaults), mode)
        }
    }

    func testLaunchAtLoginPreferenceRoundTripsInUserDefaults() throws {
        let suiteName = "LaunchAtLoginPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(LaunchAtLogin.savedPreference(from: defaults))

        LaunchAtLogin.savePreference(true, to: defaults)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: defaults), true)

        LaunchAtLogin.savePreference(false, to: defaults)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: defaults), false)
    }

    func testLaunchAtLoginChoiceSurvivesRegistrationFailureAndReopening() throws {
        let suiteName = "LaunchAtLoginFailureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        struct RegistrationFailure: Error {}

        for enabled in [true, false] {
            XCTAssertThrowsError(try LaunchAtLogin.updatePreference(enabled, to: defaults) { _ in
                throw RegistrationFailure()
            })
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            XCTAssertEqual(LaunchAtLogin.savedPreference(from: reopenedDefaults), enabled)
        }
    }

    func testNextLaunchRetriesSavedChoiceWithoutLosingItAfterAnotherFailure() throws {
        let suiteName = "LaunchAtLoginRestoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        struct RegistrationFailure: Error {}

        for enabled in [true, false] {
            XCTAssertThrowsError(try LaunchAtLogin.updatePreference(enabled, to: defaults) { _ in
                throw RegistrationFailure()
            })
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            var requests: [Bool] = []
            XCTAssertThrowsError(try LaunchAtLogin.restorePreference(from: reopenedDefaults) {
                requests.append($0)
                throw RegistrationFailure()
            })
            try LaunchAtLogin.restorePreference(from: reopenedDefaults) { requests.append($0) }
            XCTAssertEqual(requests, [enabled, enabled])
            XCTAssertEqual(LaunchAtLogin.savedPreference(from: reopenedDefaults), enabled)
        }
    }

    func testStartupDoesNotChangeLoginItemsWhenNoPreferenceWasSaved() throws {
        let suiteName = "LaunchAtLoginUnconfiguredTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try LaunchAtLogin.restorePreference(from: defaults) { _ in
            XCTFail("Startup must not change login items without a saved choice")
        }
        XCTAssertNil(LaunchAtLogin.savedPreference(from: defaults))
    }

    func testRegistrationIsIdempotentAndRespectsSystemApproval() throws {
        let cases: [(Bool, SMAppService.Status, Int, Int)] = [
            (true, .enabled, 0, 0),
            (true, .requiresApproval, 0, 0),
            (true, .notRegistered, 1, 0),
            (true, .notFound, 1, 0),
            (false, .enabled, 0, 1),
            (false, .requiresApproval, 0, 1),
            (false, .notRegistered, 0, 0),
            (false, .notFound, 0, 0)
        ]
        for (enabled, status, expectedRegistrations, expectedRemovals) in cases {
            var registrations = 0
            var removals = 0
            try LaunchAtLogin.setRegistered(
                enabled, currentStatus: status,
                register: { registrations += 1 },
                unregister: { removals += 1 }
            )
            XCTAssertEqual(registrations, expectedRegistrations)
            XCTAssertEqual(removals, expectedRemovals)
        }
    }
}

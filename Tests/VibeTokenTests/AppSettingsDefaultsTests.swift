import Foundation
import XCTest
@testable import VibeToken

final class AppSettingsDefaultsTests: XCTestCase {
    func testBundledLaunchUsesCurrentAppDefaultsWithoutOpeningOwnBundleAsSuite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        DockIconMode.menuBarOnly.save(to: fixture.firstLaunch)
        LaunchAtLogin.savePreference(true, to: fixture.firstLaunch)

        let resolved = AppSettingsDefaults.resolve(
            suiteName: fixture.firstSuite,
            legacyDefaults: fixture.firstLaunch,
            currentBundleIdentifier: fixture.firstSuite
        )

        XCTAssertTrue(resolved === fixture.firstLaunch)
        XCTAssertEqual(DockIconMode.load(from: resolved), .menuBarOnly)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: resolved), true)
        DockIconMode.always.save(to: resolved)
        LaunchAtLogin.savePreference(false, to: resolved)
        XCTAssertEqual(DockIconMode.load(from: fixture.firstLaunch), .always)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: fixture.firstLaunch), false)
    }

    func testBothSettingsSurviveAChangeOfLaunchDefaultsDomain() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let firstLaunch = AppSettingsDefaults.resolve(
            suiteName: fixture.savedSuite, legacyDefaults: fixture.firstLaunch
        )
        DockIconMode.menuBarOnly.save(to: firstLaunch)
        try LaunchAtLogin.updatePreference(true, to: firstLaunch, register: { _ in })

        let secondLaunch = AppSettingsDefaults.resolve(
            suiteName: fixture.savedSuite, legacyDefaults: fixture.secondLaunch
        )
        XCTAssertEqual(DockIconMode.load(from: secondLaunch), .menuBarOnly)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: secondLaunch), true)

        DockIconMode.always.save(to: secondLaunch)
        try LaunchAtLogin.updatePreference(false, to: secondLaunch, register: { _ in })
        let thirdLaunch = AppSettingsDefaults.resolve(
            suiteName: fixture.savedSuite, legacyDefaults: fixture.firstLaunch
        )
        XCTAssertEqual(DockIconMode.load(from: thirdLaunch), .always)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: thirdLaunch), false)
    }

    func testExistingChoicesMigrateWithoutCopyingUnrelatedPreferences() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        DockIconMode.menuBarOnly.save(to: fixture.firstLaunch)
        LaunchAtLogin.savePreference(true, to: fixture.firstLaunch)
        fixture.firstLaunch.set("fixture-value", forKey: "unrelatedSetting")

        let migrated = AppSettingsDefaults.resolve(
            suiteName: fixture.savedSuite, legacyDefaults: fixture.firstLaunch
        )
        XCTAssertEqual(DockIconMode.load(from: migrated), .menuBarOnly)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: migrated), true)
        XCTAssertNil(migrated.object(forKey: "unrelatedSetting"))
    }

    func testLegacyValuesNeverOverwriteNewerSavedChoicesIncludingFalse() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let saved = try XCTUnwrap(UserDefaults(suiteName: fixture.savedSuite))
        DockIconMode.always.save(to: saved)
        LaunchAtLogin.savePreference(false, to: saved)
        DockIconMode.menuBarOnly.save(to: fixture.firstLaunch)
        LaunchAtLogin.savePreference(true, to: fixture.firstLaunch)

        let resolved = AppSettingsDefaults.resolve(
            suiteName: fixture.savedSuite, legacyDefaults: fixture.firstLaunch
        )
        XCTAssertEqual(DockIconMode.load(from: resolved), .always)
        XCTAssertEqual(LaunchAtLogin.savedPreference(from: resolved), false)
    }

    func testFreshPreferencesDoNotInventALaunchAtLoginChoice() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolved = AppSettingsDefaults.resolve(
            suiteName: fixture.savedSuite, legacyDefaults: fixture.firstLaunch
        )
        XCTAssertEqual(DockIconMode.load(from: resolved), .always)
        XCTAssertNil(LaunchAtLogin.savedPreference(from: resolved))
    }

    private func makeFixture() throws -> Fixture {
        let prefix = "AppSettingsDefaultsTests-\(UUID().uuidString)"
        return Fixture(
            savedSuite: "\(prefix).saved",
            firstSuite: "\(prefix).first",
            secondSuite: "\(prefix).second",
            firstLaunch: try XCTUnwrap(UserDefaults(suiteName: "\(prefix).first")),
            secondLaunch: try XCTUnwrap(UserDefaults(suiteName: "\(prefix).second"))
        )
    }

    private struct Fixture {
        let savedSuite: String
        let firstSuite: String
        let secondSuite: String
        let firstLaunch: UserDefaults
        let secondLaunch: UserDefaults

        func cleanup() {
            for suite in [savedSuite, firstSuite, secondSuite] {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }
    }
}

import Foundation
import XCTest
@testable import VibeToken

final class RefreshModeTests: XCTestCase {
    func testRealTimeUsesFileEventsAndFallbackPolling() {
        let fallback = Duration.seconds(5)

        XCTAssertTrue(RefreshMode.realTime.usesFileEvents)
        XCTAssertEqual(
            RefreshMode.realTime.pollingInterval(realTimeFallback: fallback),
            fallback
        )
    }

    func testScheduledModesDoNotUseFileEvents() {
        XCTAssertFalse(RefreshMode.fiveMinutes.usesFileEvents)
        XCTAssertFalse(RefreshMode.thirtyMinutes.usesFileEvents)
        XCTAssertEqual(
            RefreshMode.fiveMinutes.pollingInterval(realTimeFallback: .seconds(5)),
            .seconds(300)
        )
        XCTAssertEqual(
            RefreshMode.thirtyMinutes.pollingInterval(realTimeFallback: .seconds(5)),
            .seconds(1_800)
        )
    }

    func testManualModeHasNoAutomaticPollingOrFileEvents() {
        XCTAssertFalse(RefreshMode.manual.usesFileEvents)
        XCTAssertNil(
            RefreshMode.manual.pollingInterval(realTimeFallback: .seconds(5))
        )
    }

    func testRefreshTimestampFormatterShowsExactSyncTimeInBothLanguages() {
        let date = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(
            RefreshTimestampFormatter.string(date, language: .simplifiedChinese, timeZone: utc),
            "同步 00:00:00"
        )
        XCTAssertEqual(
            RefreshTimestampFormatter.string(date, language: .english, timeZone: utc),
            "Synced 00:00:00"
        )
        XCTAssertEqual(
            RefreshTimestampFormatter.string(nil, language: .simplifiedChinese, timeZone: utc),
            "尚未同步"
        )
    }
}

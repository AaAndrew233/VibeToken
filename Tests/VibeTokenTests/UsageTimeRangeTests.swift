import Foundation
import XCTest
@testable import VibeToken

final class UsageTimeRangeTests: XCTestCase {
    func testTodayStartsAtLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-06T01:30:00Z"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-05T16:00:00Z"))

        XCTAssertEqual(UsageTimeRange.today.startDate(now: now, calendar: calendar), expected)
    }

    func testRollingRangesUseExactDurations() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertEqual(now.timeIntervalSince(UsageTimeRange.hours24.startDate(now: now)), 86_400)
        XCTAssertEqual(now.timeIntervalSince(UsageTimeRange.days7.startDate(now: now)), 604_800)
        XCTAssertEqual(now.timeIntervalSince(UsageTimeRange.days30.startDate(now: now)), 2_592_000)
    }
}

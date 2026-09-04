import Foundation
import XCTest
@testable import VibeToken

final class Sub2APIAccountQuotaPresentationTests: XCTestCase {
    func testCurrentQuotaKeepsPastAndMissingResetTimesVisible() throws {
        let pastReset = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-03T23:00:00Z")
        )
        let presentation = Sub2APIAccountQuotaPresentation(
            status: .current(fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 0),
            fiveHourResetAt: pastReset,
            sevenDayResetAt: nil
        )

        XCTAssertEqual(
            presentation,
            .current(
                fiveHourRemainingPercent: 100,
                sevenDayRemainingPercent: 0,
                fiveHourResetAt: pastReset,
                sevenDayResetAt: nil
            )
        )
        XCTAssertTrue(presentation.showsResetTimes)
        XCTAssertEqual(
            Sub2APIQuotaResetFormatter.string(
                from: pastReset,
                language: .simplifiedChinese,
                timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))
            ),
            "9/4 07:00"
        )
        XCTAssertEqual(
            Sub2APIQuotaResetFormatter.string(from: nil, language: .english),
            "--"
        )
    }

    func testStaleAndUnobservedQuotaDoNotExposeResetRows() {
        let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

        let stale = Sub2APIAccountQuotaPresentation(
            status: .stale,
            fiveHourResetAt: resetAt,
            sevenDayResetAt: resetAt
        )
        let unobserved = Sub2APIAccountQuotaPresentation(
            status: .unobserved,
            fiveHourResetAt: resetAt,
            sevenDayResetAt: resetAt
        )

        XCTAssertEqual(stale, .stale)
        XCTAssertFalse(stale.showsResetTimes)
        XCTAssertEqual(unobserved, .unobserved)
        XCTAssertFalse(unobserved.showsResetTimes)
    }
}

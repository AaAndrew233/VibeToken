import Foundation
import XCTest
@testable import VibeToken

final class Sub2APIAccountQuotaPresentationTests: XCTestCase {
    func testWeeklyQuotaShowsOnlyWeeklyResetAndExhaustion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(600)
        let current = Sub2APIAccountQuotaStatus(
            fiveHourUsedPercent: nil, sevenDayUsedPercent: 25,
            usageUpdatedAt: now, observedAt: now, staleAfter: 900,
            explicitlyLimited: false, sevenDayResetAt: reset, requiresFiveHourWindow: false
        )
        XCTAssertEqual(current, .weekly(sevenDayRemainingPercent: 75))
        XCTAssertFalse(current.isExhausted)
        let presentation = Sub2APIAccountQuotaPresentation(
            status: current, fiveHourResetAt: now, sevenDayResetAt: reset
        )
        XCTAssertEqual(presentation, .weekly(sevenDayRemainingPercent: 75, sevenDayResetAt: reset))
        XCTAssertTrue(presentation.showsResetTimes)
        XCTAssertTrue(Sub2APIAccountQuotaStatus.weekly(sevenDayRemainingPercent: 0).isExhausted)
    }

    func testWeeklyPlanDoesNotInventMissingOrStaleQuota() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(Double?, Date?, Date?, Sub2APIAccountQuotaStatus)] = [
            (nil, now, nil, .unobserved),
            (25, nil, nil, .unobserved),
            (25, now.addingTimeInterval(-901), nil, .stale),
            (100, now, now, .stale),
            (100, now, now.addingTimeInterval(60), .weekly(sevenDayRemainingPercent: 0))
        ]
        for (used, updated, reset, expected) in cases {
            XCTAssertEqual(Sub2APIAccountQuotaStatus(
                fiveHourUsedPercent: nil, sevenDayUsedPercent: used,
                usageUpdatedAt: updated, observedAt: now, staleAfter: 900,
                explicitlyLimited: false, sevenDayResetAt: reset, requiresFiveHourWindow: false
            ), expected)
        }
    }

    func testSchedulableAccountDoesNotBecomeUnavailableWhenQuotaIsUnknown() {
        for quotaStatus in [Sub2APIAccountQuotaStatus.stale, .unobserved] {
            let option = Sub2APIAccountCapacityOption(
                accountID: 1,
                displayName: "Test account",
                detectedPlan: "Pro",
                selectedTier: .pro20,
                runtimeStatus: .available,
                quotaStatus: quotaStatus,
                fiveHourResetAt: nil,
                sevenDayResetAt: nil,
                nextRecoveryAt: nil
            )

            XCTAssertTrue(option.isAvailableForDisplay)
            XCTAssertFalse(option.isInvalidForSorting)
        }
    }

    func testConfirmedRuntimeBlocksAndCurrentExhaustionRemainUnavailable() {
        let cases: [(Sub2APIAccountRuntimeStatus, Sub2APIAccountQuotaStatus)] = [
            (.unavailable, .current(fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 100)),
            (.rateLimited, .stale),
            (.available, .current(fiveHourRemainingPercent: 0, sevenDayRemainingPercent: 100))
        ]
        for (runtimeStatus, quotaStatus) in cases {
            let option = Sub2APIAccountCapacityOption(
                accountID: 1,
                displayName: nil,
                detectedPlan: "Plus",
                selectedTier: .plus,
                runtimeStatus: runtimeStatus,
                quotaStatus: quotaStatus,
                fiveHourResetAt: nil,
                sevenDayResetAt: nil,
                nextRecoveryAt: nil
            )

            XCTAssertFalse(option.isAvailableForDisplay)
        }
    }

    func testExpiredQuotaWindowCannotHideAnotherConfirmedBlock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scenarios: [(Double?, Date?, Sub2APIAccountQuotaStatus)] = [
            (20, nil, .stale),
            (100, now.addingTimeInterval(-1), .stale),
            (100, now.addingTimeInterval(600), .exhaustedWithIncompleteData),
            (100, nil, .exhaustedWithIncompleteData)
        ]
        for (sevenDayUsed, sevenDayReset, expected) in scenarios {
            let status = Sub2APIAccountQuotaStatus(
                fiveHourUsedPercent: 100,
                sevenDayUsedPercent: sevenDayUsed,
                usageUpdatedAt: now,
                observedAt: now,
                staleAfter: 900,
                explicitlyLimited: false,
                fiveHourResetAt: now,
                sevenDayResetAt: sevenDayReset
            )
            XCTAssertEqual(status, expected)
        }
        XCTAssertEqual(
            Sub2APIAccountQuotaStatus(
                fiveHourUsedPercent: nil,
                sevenDayUsedPercent: 100,
                usageUpdatedAt: now,
                observedAt: now,
                staleAfter: 900,
                explicitlyLimited: false
            ),
            .exhaustedWithIncompleteData
        )
    }

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

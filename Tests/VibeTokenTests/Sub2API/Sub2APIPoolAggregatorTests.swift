import Foundation
import XCTest
@testable import VibeToken

final class Sub2APIPoolAggregatorTests: XCTestCase {
    func testAggregatesPhysicalSchedulableAccountsAndExcludesShadows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accounts = [
            account(id: 1, plan: "Pro", fiveHour: 0, sevenDay: 20, updatedAt: now),
            account(
                id: 2,
                plan: "Pro",
                fiveHour: 50,
                sevenDay: 100,
                updatedAt: now.addingTimeInterval(-1_000)
            ),
            account(id: 3, plan: "Unknown", fiveHour: nil, sevenDay: nil, updatedAt: nil),
            account(id: 4, status: "error", schedulable: false, plan: "Pro", fiveHour: 10, sevenDay: 10, updatedAt: now),
            account(id: 5, parentID: 1, plan: "Pro", fiveHour: 0, sevenDay: 0, updatedAt: now)
        ]

        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: accounts,
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.totalAccounts, 4)
        XCTAssertEqual(snapshot.eligibleAccounts, 3)
        XCTAssertEqual(snapshot.unavailableAccounts, 1)
        XCTAssertEqual(snapshot.excludedShadowAccounts, 1)
        XCTAssertEqual(snapshot.missingWindowAccounts, 1)
        XCTAssertEqual(snapshot.staleWindowAccounts, 0)
        XCTAssertEqual(snapshot.effectiveCapacity.observedAccounts, 2)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccounts, 1)
        XCTAssertEqual(snapshot.effectiveCapacity.windowLimitedAccounts, 1)
        XCTAssertEqual(snapshot.effectiveCapacity.remainingEquivalentAccounts, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccountRemainingFraction, 0.8)
        XCTAssertEqual(snapshot.fiveHour.observedAccounts, 2)
        XCTAssertEqual(snapshot.fiveHour.remainingEquivalentAccounts, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour.remainingFraction), 0.75, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.sevenDay.remainingEquivalentAccounts, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.plans.first?.plan, "Pro")
        XCTAssertEqual(snapshot.plans.first?.accountCount, 2)
    }

    func testClampsInvalidUpstreamPercentages() {
        let now = Date()
        let accounts = [
            account(id: 1, fiveHour: -20, sevenDay: 150, updatedAt: now),
            account(id: 2, fiveHour: 500, sevenDay: -1, updatedAt: now)
        ]

        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: accounts,
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.fiveHour.remainingEquivalentAccounts, 1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.sevenDay.remainingEquivalentAccounts, 1, accuracy: 0.000_001)
    }

    func testCountsEachPhysicalAccountIDOnlyOnce() {
        let now = Date()
        let accounts = [
            account(id: 1, fiveHour: 10, sevenDay: 20, updatedAt: now),
            account(id: 1, fiveHour: 30, sevenDay: 40, updatedAt: now),
            account(id: 2, parentID: 1, fiveHour: 0, sevenDay: 0, updatedAt: now),
            account(id: 2, parentID: 1, fiveHour: 0, sevenDay: 0, updatedAt: now)
        ]

        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: accounts,
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.totalAccounts, 1)
        XCTAssertEqual(snapshot.eligibleAccounts, 1)
        XCTAssertEqual(snapshot.excludedShadowAccounts, 1)
        XCTAssertEqual(snapshot.fiveHour.observedAccounts, 1)
        XCTAssertEqual(snapshot.fiveHour.remainingEquivalentAccounts, 0.7, accuracy: 0.000_001)
    }

    func testEffectiveCapacityRequiresBothWindowsToHaveRemainingQuota() throws {
        let now = Date()
        let accounts = (1...11).map { id in
            account(
                id: Int64(id),
                plan: id <= 7 ? "Plus" : "Pro",
                fiveHour: 0,
                sevenDay: id == 1 ? 21 : 100,
                updatedAt: now
            )
        }

        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: accounts,
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.eligibleAccounts, 11)
        XCTAssertEqual(snapshot.totalCapacityAccounts, 11)
        XCTAssertEqual(snapshot.displayedAvailableAccountFraction, 1.0 / 11.0)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.displayedRemainingFraction),
            0.79 / 11,
            accuracy: 0.000_001
        )
        XCTAssertEqual(snapshot.effectiveCapacity.observedAccounts, 11)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccounts, 1)
        XCTAssertEqual(snapshot.effectiveCapacity.windowLimitedAccounts, 10)
        XCTAssertEqual(snapshot.fiveHour.remainingFraction, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.sevenDay.remainingFraction), 0.79 / 11, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveCapacity.remainingEquivalentAccounts, 0.79, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveCapacity.fiveHourRemainingEquivalentAccounts, 11, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveCapacity.sevenDayRemainingEquivalentAccounts, 0.79, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccountFraction, 1.0 / 11.0)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccountRemainingFraction, 0.79)
        XCTAssertEqual(snapshot.effectiveCapacity.totalAvailableRemainingFraction, 0.79)
        XCTAssertEqual(snapshot.effectiveCapacity.availableFiveHourRemainingFraction, 1)
        XCTAssertEqual(snapshot.effectiveCapacity.availableSevenDayRemainingFraction, 0.79)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.effectiveCapacity.poolRemainingFraction),
            0.79 / 11,
            accuracy: 0.000_001
        )
    }

    func testExhaustedWindowTakesPrecedenceOverStaleUsageTimestamp() {
        let now = Date()
        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: [
                account(
                    id: 1,
                    fiveHour: 0,
                    sevenDay: 100,
                    updatedAt: now.addingTimeInterval(-1_000)
                )
            ],
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.staleWindowAccounts, 0)
        XCTAssertEqual(snapshot.missingWindowAccounts, 0)
        XCTAssertEqual(snapshot.effectiveCapacity.observedAccounts, 1)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccounts, 0)
        XCTAssertEqual(snapshot.effectiveCapacity.windowLimitedAccounts, 1)
        XCTAssertEqual(snapshot.effectiveCapacity.remainingEquivalentAccounts, 0)
    }

    func testOfficialRuntimeStatusSeparatesRateLimitedAndUnavailableAccounts() {
        let now = Date()
        let accounts = [
            account(
                id: 1,
                schedulable: false,
                fiveHour: 20,
                sevenDay: 30,
                updatedAt: now,
                rateLimitResetAt: now.addingTimeInterval(600)
            ),
            account(
                id: 2,
                fiveHour: 10,
                sevenDay: 20,
                updatedAt: now,
                tempUnschedulableUntil: now.addingTimeInterval(600)
            ),
            account(
                id: 3,
                fiveHour: 10,
                sevenDay: 20,
                updatedAt: now,
                overloadUntil: now.addingTimeInterval(600)
            ),
            account(
                id: 4,
                status: "error",
                fiveHour: 10,
                sevenDay: 20,
                updatedAt: now
            ),
            account(
                id: 5,
                schedulable: false,
                fiveHour: 0,
                sevenDay: 100,
                updatedAt: now
            ),
            account(
                id: 6,
                fiveHour: 0,
                sevenDay: 100,
                updatedAt: now,
                tempUnschedulableUntil: now.addingTimeInterval(600)
            )
        ]

        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: accounts,
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.totalAccounts, 6)
        XCTAssertEqual(snapshot.eligibleAccounts, 1)
        XCTAssertEqual(snapshot.unavailableAccounts, 5)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccounts, 0)
        XCTAssertEqual(snapshot.effectiveCapacity.windowLimitedAccounts, 1)
        XCTAssertEqual(snapshot.effectiveCapacity.nextRecoveryAt, now.addingTimeInterval(600))
    }

    func testMissingOrStaleWindowIsNotReportedAsCurrentlyAvailable() {
        let now = Date()
        let accounts = [
            account(id: 1, fiveHour: 0, sevenDay: nil, updatedAt: now),
            account(id: 2, fiveHour: 0, sevenDay: 0, updatedAt: now.addingTimeInterval(-1_000))
        ]

        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: accounts,
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.missingWindowAccounts, 1)
        XCTAssertEqual(snapshot.staleWindowAccounts, 1)
        XCTAssertEqual(snapshot.totalCapacityAccounts, 2)
        XCTAssertEqual(snapshot.displayedAvailableAccountFraction, 0)
        XCTAssertEqual(snapshot.displayedRemainingFraction, 0)
        XCTAssertEqual(snapshot.effectiveCapacity.observedAccounts, 0)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccounts, 0)
        XCTAssertNil(snapshot.effectiveCapacity.poolRemainingFraction)
        XCTAssertNil(snapshot.effectiveCapacity.availableAccountRemainingFraction)
        XCTAssertNil(snapshot.effectiveCapacity.totalAvailableRemainingFraction)
    }

    func testTotalAvailableCapacityAddsUsableAccountsInsteadOfAveragingThem() throws {
        let now = Date()
        let accounts = [
            account(id: 1, fiveHour: 20, sevenDay: 10, updatedAt: now),
            account(id: 2, fiveHour: 40, sevenDay: 20, updatedAt: now)
        ]

        let snapshot = Sub2APIPoolAggregator.aggregate(
            accounts: accounts,
            fetchedAt: now,
            staleAfter: 900
        )

        XCTAssertEqual(snapshot.effectiveCapacity.availableAccounts, 2)
        XCTAssertEqual(snapshot.effectiveCapacity.availableAccountRemainingFraction, 0.7)
        XCTAssertEqual(snapshot.effectiveCapacity.totalAvailableRemainingFraction, 1.4)
        XCTAssertEqual(snapshot.effectiveCapacity.totalAvailableFiveHourRemainingFraction, 1.4)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.effectiveCapacity.totalAvailableSevenDayRemainingFraction),
            1.7,
            accuracy: 0.000_001
        )
        XCTAssertEqual(snapshot.effectiveCapacity.fiveHourRemainingEquivalentAccounts, 1.4, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveCapacity.sevenDayRemainingEquivalentAccounts, 1.7, accuracy: 0.000_001)
    }

    private func account(
        id: Int64,
        status: String = "active",
        schedulable: Bool = true,
        parentID: Int64? = nil,
        plan: String = "Pro",
        fiveHour: Double?,
        sevenDay: Double?,
        updatedAt: Date?,
        rateLimitResetAt: Date? = nil,
        overloadUntil: Date? = nil,
        tempUnschedulableUntil: Date? = nil
    ) -> Sub2APIAccountSnapshot {
        Sub2APIAccountSnapshot(
            id: id,
            status: status,
            schedulable: schedulable,
            parentAccountID: parentID,
            plan: plan,
            fiveHourUsedPercent: fiveHour,
            fiveHourResetAt: nil,
            sevenDayUsedPercent: sevenDay,
            sevenDayResetAt: nil,
            usageUpdatedAt: updatedAt,
            rateLimitResetAt: rateLimitResetAt,
            overloadUntil: overloadUntil,
            tempUnschedulableUntil: tempUnschedulableUntil
        )
    }
}

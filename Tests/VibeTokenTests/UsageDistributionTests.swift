import Foundation
import XCTest
@testable import VibeToken

final class UsageDistributionTests: XCTestCase {
    func testTokenSlicesSortDescendingAndMergeAfterSixItems() {
        let items = stride(from: 8, through: 1, by: -1).map { index in
            item(id: "model-\(index)", tokens: Int64(index * 100), costMicros: Int64(index * 10))
        }

        let slices = UsageDistributionBuilder.slices(
            from: items,
            metric: .tokens,
            otherLabel: "其他"
        )

        XCTAssertEqual(slices.count, 7)
        XCTAssertEqual(slices.prefix(6).map(\.value), [800, 700, 600, 500, 400, 300])
        XCTAssertEqual(slices.last?.displayName, "其他")
        XCTAssertEqual(slices.last?.value, 300)
    }

    func testCostSlicesExcludeUnpricedModelsWithoutDroppingTokenSlices() {
        let items = [
            item(id: "priced", tokens: 100, costMicros: 25),
            item(id: "unknown", tokens: 300, costMicros: nil)
        ]

        let tokenSlices = UsageDistributionBuilder.slices(
            from: items,
            metric: .tokens,
            otherLabel: "其他"
        )
        let costSlices = UsageDistributionBuilder.slices(
            from: items,
            metric: .cost,
            otherLabel: "其他"
        )

        XCTAssertEqual(tokenSlices.map(\.id), ["unknown", "priced"])
        XCTAssertEqual(costSlices.map(\.id), ["priced"])
    }

    func testPercentageUsesDecimalAndHandlesZeroTotal() {
        XCTAssertEqual(
            UsageDistributionBuilder.percentage(value: 100, total: 400),
            Decimal(25)
        )
        XCTAssertEqual(
            UsageDistributionBuilder.percentage(value: 100, total: 0),
            Decimal.zero
        )
    }

    private func item(id: String, tokens: Int64, costMicros: Int64?) -> UsageDistributionItem {
        UsageDistributionItem(
            id: id,
            displayName: id,
            totalTokens: tokens,
            estimatedCost: costMicros.map { MoneyAmount(micros: $0, currencyCode: "USD") },
            isCostComplete: costMicros != nil
        )
    }
}

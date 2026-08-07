import Foundation
import XCTest
@testable import VibeToken

final class FormatterTests: XCTestCase {
    func testTokenFormatterUsesCompactSuffixes() {
        let value = TokenFormatter.string(
            12_345_678_901,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(value, "12.3B")
        XCTAssertFalse(value.lowercased().contains("e"))
        XCTAssertEqual(
            TokenFormatter.string(36_900_000, locale: Locale(identifier: "en_US")),
            "36.9M"
        )
        XCTAssertEqual(
            TokenFormatter.string(999, locale: Locale(identifier: "en_US")),
            "999"
        )
    }

    func testMoneyFormatterUsesFixedDecimalNotation() {
        let value = MoneyFormatter.string(
            MoneyAmount(micros: 12_860_000, currencyCode: "CNY"),
            locale: Locale(identifier: "zh_CN")
        )
        XCTAssertTrue(value.contains("12.86"))
        XCTAssertFalse(value.lowercased().contains("e"))
    }

    func testMenuBarSummaryShowsCompactTokensAndEstimatedCost() {
        let value = MenuBarSummaryFormatter.string(
            tokens: 123_456_789,
            estimatedCost: MoneyAmount(micros: 12_860_000, currencyCode: "CNY"),
            locale: Locale(identifier: "zh_CN")
        )

        XCTAssertTrue(value.hasPrefix("123.5M｜"))
        XCTAssertTrue(value.contains("12.86"))
        XCTAssertFalse(value.lowercased().contains("e"))
    }

    func testMenuBarSummaryUsesPlaceholderUntilPricingIsAvailable() {
        let value = MenuBarSummaryFormatter.string(
            tokens: 123_456_789,
            estimatedCost: nil,
            locale: Locale(identifier: "zh_CN")
        )

        XCTAssertEqual(value, "123.5M｜--")
    }

    func testMoneyFormatterCompactsLargeAmounts() {
        let value = MoneyFormatter.string(
            MoneyAmount(micros: 3_358_951_996, currencyCode: "USD"),
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(value, "$3.36K")
    }

    func testTokenInterpolationStaysWithinRealValueBounds() {
        XCTAssertEqual(TokenValueInterpolation.value(from: 100, to: 200, progress: -1), 100)
        XCTAssertEqual(TokenValueInterpolation.value(from: 100, to: 200, progress: 0.5), 150)
        XCTAssertEqual(TokenValueInterpolation.value(from: 100, to: 200, progress: 2), 200)
        XCTAssertEqual(TokenValueInterpolation.value(from: 200, to: 100, progress: 0.5), 150)
    }
}

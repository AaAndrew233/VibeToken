import Foundation
import XCTest
@testable import VibeToken

final class CostEstimatorTests: XCTestCase {
    private let estimator = CostEstimator(catalog: .officialAPI)

    func testUsesDocumentedFormulaForStandardCodexPricing() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-5.6-sol")))

        XCTAssertEqual(estimate.amount, MoneyAmount(micros: 70_500_000, currencyCode: "USD"))
        XCTAssertEqual(estimate.matchedModel, "gpt-5.6-sol")
        XCTAssertNil(estimate.tier)
    }

    func testUsesTierPricingWhenModelCarriesFlexSuffix() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-5.6-sol-flex")))

        XCTAssertEqual(estimate.amount, MoneyAmount(micros: 35_250_000, currencyCode: "USD"))
        XCTAssertEqual(estimate.tier, "flex")
    }

    func testUsesPublicAliasForDefaultGpt56Model() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "openai/gpt-5.6")))

        XCTAssertEqual(estimate.matchedModel, "gpt-5.6-sol")
        XCTAssertEqual(estimate.amount.micros, 70_500_000)
    }

    func testPricesClaudeModelFromClaudeCodeIdentifier() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "claude-sonnet-4-5")))

        XCTAssertEqual(estimate.matchedModel, "claude-sonnet-4-5")
        XCTAssertEqual(estimate.amount.micros, 36_300_000)
    }

    func testPricesVersionedClaudeModelFromOpenCodeProviderIdentifier() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "anthropic/claude-sonnet-4-5-20250929"
        )))

        XCTAssertEqual(estimate.matchedModel, "claude-sonnet-4-5")
        XCTAssertEqual(estimate.amount.micros, 36_300_000)
    }

    func testClaudeSonnet5UsesIntroductoryPriceBeforeSeptember2026() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "claude-sonnet-5",
            recordedAt: Date(timeIntervalSince1970: 1_788_220_799)
        )))

        XCTAssertEqual(estimate.amount.micros, 24_200_000)
    }

    func testClaudeSonnet5UsesStandardPriceStartingSeptember2026() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "claude-sonnet-5",
            recordedAt: Date(timeIntervalSince1970: 1_788_220_800)
        )))

        XCTAssertEqual(estimate.amount.micros, 36_300_000)
    }

    func testPricesGeminiProFromGeminiCLIIdentifier() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gemini-2.5-pro")))

        XCTAssertEqual(estimate.matchedModel, "gemini-2-5-pro")
        XCTAssertEqual(estimate.amount.micros, 22_625_000)
    }

    func testPricesGeminiModelFromOpenCodeProviderIdentifier() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "google/gemini-3.1-pro-preview-customtools"
        )))

        XCTAssertEqual(estimate.matchedModel, "gemini-3-1-pro-preview")
        XCTAssertEqual(estimate.amount.micros, 28_200_000)
    }

    func testCatalogRetainsOfficialVerificationMetadata() {
        XCTAssertEqual(PricingCatalog.officialAPI.version, "official-api-2026-08-07-v1")
        XCTAssertEqual(PricingCatalog.officialAPI.sourceURLs.count, 3)
        XCTAssertEqual(
            PricingCatalog.officialAPI.verifiedAt,
            Date(timeIntervalSince1970: 1_786_060_800)
        )
    }

    func testUnknownModelRemainsUnpriced() {
        XCTAssertNil(estimator.estimate(for: snapshot(model: "unknown-private-model")))
    }

    func testMissingModelRemainsUnpriced() {
        XCTAssertNil(estimator.estimate(for: snapshot(model: nil)))
    }

    func testNegativeTokenValuesAreTreatedAsZero() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "gpt-5.6-sol",
            inputTokens: -1,
            cachedInputTokens: -1,
            cacheWriteTokens: -1,
            outputTokens: -1,
            reasoningTokens: -1
        )))

        XCTAssertEqual(estimate.amount.micros, 0)
    }

    func testExtremeTokenValuesDoNotOverflowBeforeDecimalCalculation() {
        let estimate = estimator.estimate(for: snapshot(
            model: "gpt-5.6-sol",
            inputTokens: .max,
            cachedInputTokens: .max,
            cacheWriteTokens: .max,
            outputTokens: .max,
            reasoningTokens: .max
        ))

        XCTAssertNil(estimate)
    }

    func testAggregateCostSumsKnownModels() throws {
        let total = try XCTUnwrap(estimator.estimate(for: [
            snapshot(model: "gpt-5.6-sol"),
            snapshot(model: "gpt-5.6-sol-flex")
        ]))

        XCTAssertEqual(total.micros, 105_750_000)
    }

    func testAggregateCostIsUnavailableWhenAnyModelIsUnknown() {
        XCTAssertNil(estimator.estimate(for: [
            snapshot(model: "gpt-5.6-sol"),
            snapshot(model: "unknown-private-model")
        ]))
    }

    func testKnownCostRemainsAvailableWithCoverageWhenSomeModelsAreUnknown() throws {
        let known = snapshot(model: "gpt-5.6-sol")
        let unknown = snapshot(model: "unknown-private-model")

        let result = try XCTUnwrap(estimator.estimateKnown(for: [known, unknown]))

        XCTAssertEqual(result.amount.micros, 70_500_000)
        XCTAssertEqual(result.pricedTokens, 5_000_000)
        XCTAssertEqual(result.totalTokens, 10_000_000)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.coveragePercentage, Decimal(50))
    }

    func testKnownCostIsUnavailableWhenNoModelsHavePricing() {
        XCTAssertNil(estimator.estimateKnown(for: [
            snapshot(model: "unknown-private-model")
        ]))
    }

    private func snapshot(
        model: String?,
        inputTokens: Int64 = 1_000_000,
        cachedInputTokens: Int64 = 1_000_000,
        cacheWriteTokens: Int64 = 1_000_000,
        outputTokens: Int64 = 1_000_000,
        reasoningTokens: Int64 = 1_000_000,
        recordedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            source: "codex",
            model: model,
            sessionIdentifier: "test",
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: 0,
            recordedAt: recordedAt,
            accuracy: .exact
        )
    }
}

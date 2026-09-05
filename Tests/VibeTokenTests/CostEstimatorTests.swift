import Foundation
import XCTest
@testable import VibeToken

final class CostEstimatorTests: XCTestCase {
    private let estimator = CostEstimator(catalog: .officialAPI)

    func testUsesDocumentedFormulaForStandardCodexPricing() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-5.6-sol")))

        XCTAssertEqual(estimate.amount, MoneyAmount(micros: 49_400_000, currencyCode: "USD"))
        XCTAssertEqual(estimate.matchedModel, "gpt-5.6-sol")
        XCTAssertNil(estimate.tier)
    }

    func testUsesTierPricingWhenModelCarriesFlexSuffix() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-5.6-sol-flex")))

        XCTAssertEqual(estimate.amount, MoneyAmount(micros: 24_700_000, currencyCode: "USD"))
        XCTAssertEqual(estimate.tier, "flex")
    }

    func testUsesPublicAliasForDefaultGpt56Model() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(model: "openai/gpt-5.6")))

        XCTAssertEqual(estimate.matchedModel, "gpt-5.6-sol")
        XCTAssertEqual(estimate.amount.micros, 49_400_000)
    }

    func testPricesGPT6AstraShortAndLongContextWithDistinctCacheWrites() throws {
        let short = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-6-astra")))
        let long = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "openai/gpt-6",
            pricingContext: .long
        )))

        XCTAssertEqual(short.matchedModel, "gpt-6-astra")
        XCTAssertEqual(short.amount.micros, 123_500_000)
        XCTAssertEqual(long.matchedModel, "gpt-6-astra")
        XCTAssertEqual(long.amount.micros, 197_000_000)
    }

    func testPricesGPT6AstraProcessingTiersForBothContextBands() throws {
        let flexShort = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-6-astra-flex")))
        let flexLong = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "gpt-6-astra-flex",
            pricingContext: .long
        )))
        let batch = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-6-astra-batch")))
        let fastShort = try XCTUnwrap(estimator.estimate(for: snapshot(model: "gpt-6-astra-fast")))
        let priorityLong = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "gpt-6-astra-priority",
            pricingContext: .long
        )))

        XCTAssertEqual(flexShort.amount.micros, 61_750_000)
        XCTAssertEqual(flexLong.amount.micros, 98_500_000)
        XCTAssertEqual(batch.amount.micros, 61_750_000)
        XCTAssertEqual(fastShort.amount.micros, 247_000_000)
        XCTAssertEqual(priorityLong.amount.micros, 394_000_000)
        XCTAssertEqual(fastShort.tier, "fast")
        XCTAssertEqual(priorityLong.tier, "priority")
    }

    func testGPT6AstraCacheWriteUsesOfficialWriteRate() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "gpt-6-astra",
            inputTokens: 0,
            cachedInputTokens: 0,
            cacheWriteTokens: 1_000_000,
            outputTokens: 0,
            reasoningTokens: 0
        )))

        XCTAssertEqual(estimate.amount.micros, 12_500_000)
    }

    func testGPT6AstraCatalogMatchesEveryOfficialPriceColumn() throws {
        let catalog = PricingCatalog.officialAPI
        let date = Date(timeIntervalSince1970: 1_788_566_400)
        let cases: [(String, PricingContext, TokenPriceRate)] = [
            ("gpt-6-astra", .short, priceRate(10, 1, 12.5, 50)),
            ("gpt-6-astra", .long, priceRate(20, 2, 25, 75)),
            ("gpt-6-astra-flex", .short, priceRate(5, 0.5, 6.25, 25)),
            ("gpt-6-astra-flex", .long, priceRate(10, 1, 12.5, 37.5)),
            ("gpt-6-astra-batch", .long, priceRate(10, 1, 12.5, 37.5)),
            ("gpt-6-astra-fast", .short, priceRate(20, 2, 25, 100)),
            ("gpt-6-astra-priority", .long, priceRate(40, 4, 50, 150))
        ]

        for (model, context, expectedRate) in cases {
            let match = try XCTUnwrap(catalog.match(model: model, at: date, context: context))
            XCTAssertEqual(match.rate, expectedRate, "\(model) \(context)")
        }
    }

    func testGPT56FlagshipModelsUseOfficialContextRates() throws {
        let cases: [(String, PricingContext, Int64)] = [
            ("gpt-5.6-terra", .short, 28_700_000),
            ("gpt-5.6-terra", .long, 45_400_000),
            ("gpt-5.6-luna", .short, 2_870_000),
            ("gpt-5.6-luna", .long, 4_540_000)
        ]

        for (model, context, expectedMicros) in cases {
            let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
                model: model,
                pricingContext: context
            )))
            XCTAssertEqual(estimate.amount.micros, expectedMicros, model)
        }
    }

    func testLegacyModelCacheWriteFallsBackToInputRate() throws {
        let estimate = try XCTUnwrap(estimator.estimate(for: snapshot(
            model: "gpt-5.2",
            inputTokens: 0,
            cachedInputTokens: 0,
            cacheWriteTokens: 1_000_000,
            outputTokens: 0,
            reasoningTokens: 0
        )))

        XCTAssertEqual(estimate.amount.micros, 1_750_000)
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
        XCTAssertEqual(PricingCatalog.officialAPI.version, "official-api-2026-09-05-v2")
        XCTAssertEqual(PricingCatalog.officialAPI.sourceURLs.count, 3)
        XCTAssertEqual(
            PricingCatalog.officialAPI.verifiedAt,
            Date(timeIntervalSince1970: 1_788_566_400)
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

        XCTAssertEqual(total.micros, 74_100_000)
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

        XCTAssertEqual(result.amount.micros, 49_400_000)
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
        recordedAt: Date = Date(timeIntervalSince1970: 0),
        pricingContext: PricingContext = .short
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
            accuracy: .exact,
            pricingContext: pricingContext
        )
    }

    private func priceRate(
        _ input: Double,
        _ cachedInput: Double,
        _ cacheWriteInput: Double,
        _ output: Double
    ) -> TokenPriceRate {
        TokenPriceRate(
            inputMicrosPerMillion: Int64(input * 1_000_000),
            outputMicrosPerMillion: Int64(output * 1_000_000),
            cachedInputMicrosPerMillion: Int64(cachedInput * 1_000_000),
            cacheWriteInputMicrosPerMillion: Int64(cacheWriteInput * 1_000_000)
        )
    }
}

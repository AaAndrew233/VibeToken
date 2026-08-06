import Foundation

struct PricingCatalog: Sendable {
    let version: String
    private let rules: [String: ModelPricingRule]
    private let aliases: [String: String]

    init(
        version: String,
        rules: [ModelPricingRule],
        aliases: [String: String] = [:]
    ) {
        self.version = version
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.canonicalModel, $0) })
        self.aliases = aliases
    }

    func match(model rawModel: String) -> MatchedModelPricing? {
        var normalizedModel = Self.normalize(rawModel)
        var tier: String?

        for candidateTier in ["priority", "flex", "batch"] where normalizedModel.hasSuffix("-\(candidateTier)") {
            normalizedModel.removeLast(candidateTier.count + 1)
            tier = candidateTier
            break
        }

        let canonicalModel = aliases[normalizedModel] ?? normalizedModel
        guard let rule = rules[canonicalModel] else { return nil }
        let rate = tier.flatMap { rule.tierRates[$0] } ?? rule.standardRate

        return MatchedModelPricing(
            canonicalModel: canonicalModel,
            tier: tier.flatMap { rule.tierRates[$0] == nil ? nil : $0 },
            rate: rate,
            catalogVersion: version
        )
    }

    private static func normalize(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let separator = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: separator)...])
    }
}

extension PricingCatalog {
    static let vibeCafeCompatibleCodex = PricingCatalog(
        version: "vibecafe-web-2026-08-06",
        rules: [
            rule("gpt-5", 1_250_000, 10_000_000, 125_000),
            rule("gpt-5-mini", 250_000, 2_000_000, 25_000),
            rule("gpt-5-nano", 50_000, 400_000, 5_000),
            rule("gpt-5.1", 1_250_000, 10_000_000, 125_000),
            rule("gpt-5.2", 1_750_000, 14_000_000, 175_000),
            rule("gpt-5.3-codex", 1_750_000, 14_000_000, 175_000),
            rule("gpt-5.4", 2_500_000, 15_000_000, 250_000),
            rule("gpt-5.4-mini", 750_000, 4_500_000, 75_000),
            rule("gpt-5.4-nano", 200_000, 1_250_000, 20_000),
            rule(
                "gpt-5.5",
                5_000_000,
                30_000_000,
                500_000,
                tiers: [
                    "priority": rate(12_500_000, 75_000_000, 1_250_000),
                    "flex": rate(2_500_000, 15_000_000, 250_000)
                ]
            ),
            rule(
                "gpt-5.6-sol",
                5_000_000,
                30_000_000,
                500_000,
                tiers: [
                    "priority": rate(10_000_000, 60_000_000, 1_000_000),
                    "flex": rate(2_500_000, 15_000_000, 250_000),
                    "batch": rate(2_500_000, 15_000_000, 250_000)
                ]
            ),
            rule(
                "gpt-5.6-terra",
                2_000_000,
                12_000_000,
                200_000,
                tiers: [
                    "priority": rate(4_000_000, 24_000_000, 400_000),
                    "flex": rate(1_000_000, 6_000_000, 100_000),
                    "batch": rate(1_000_000, 6_000_000, 100_000)
                ]
            ),
            rule(
                "gpt-5.6-luna",
                200_000,
                1_200_000,
                20_000,
                tiers: [
                    "priority": rate(400_000, 2_400_000, 40_000),
                    "flex": rate(100_000, 600_000, 10_000),
                    "batch": rate(100_000, 600_000, 10_000)
                ]
            ),
            rule("gpt-5.5-codex", 2_500_000, 15_000_000, 250_000),
            rule("gpt-5.4-codex", 2_500_000, 15_000_000, 250_000),
            rule("gpt-5-codex", 1_250_000, 10_000_000, 125_000),
            rule("gpt-5.2-codex", 1_750_000, 14_000_000, 175_000),
            rule("gpt-5.1-codex", 1_250_000, 10_000_000, 125_000),
            rule("gpt-5.1-codex-mini", 250_000, 2_000_000, 25_000),
            rule("gpt-5.1-codex-max", 1_250_000, 10_000_000, 125_000),
            rule("codex-mini-latest", 1_500_000, 6_000_000, 375_000)
        ],
        aliases: [
            "gpt-5.6": "gpt-5.6-sol",
            "gpt-5-6": "gpt-5.6-sol",
            "gpt-5-6-sol": "gpt-5.6-sol",
            "gpt-5-6-terra": "gpt-5.6-terra",
            "gpt-5-6-luna": "gpt-5.6-luna"
        ]
    )

    private static func rule(
        _ model: String,
        _ input: Int64,
        _ output: Int64,
        _ cachedInput: Int64?,
        tiers: [String: TokenPriceRate] = [:]
    ) -> ModelPricingRule {
        ModelPricingRule(
            canonicalModel: model,
            standardRate: rate(input, output, cachedInput),
            tierRates: tiers
        )
    }

    private static func rate(
        _ input: Int64,
        _ output: Int64,
        _ cachedInput: Int64?
    ) -> TokenPriceRate {
        TokenPriceRate(
            inputMicrosPerMillion: input,
            outputMicrosPerMillion: output,
            cachedInputMicrosPerMillion: cachedInput
        )
    }
}

import Foundation

struct PricingCatalog: Sendable {
    let version: String
    let verifiedAt: Date
    let sourceURLs: [String]
    private let rules: [String: [ModelPricingRule]]
    private let aliases: [String: String]

    init(
        version: String,
        verifiedAt: Date,
        sourceURLs: [String],
        rules: [ModelPricingRule],
        aliases: [String: String] = [:]
    ) {
        self.version = version
        self.verifiedAt = verifiedAt
        self.sourceURLs = sourceURLs
        self.rules = Dictionary(grouping: rules, by: \.canonicalModel)
            .mapValues { periods in
                periods.sorted {
                    ($0.effectiveFrom ?? .distantPast) > ($1.effectiveFrom ?? .distantPast)
                }
            }
        self.aliases = aliases
    }

    func match(model rawModel: String, at date: Date) -> MatchedModelPricing? {
        var normalizedModel = Self.normalize(rawModel)
        var tier: String?

        for candidateTier in ["priority", "flex", "batch"] where normalizedModel.hasSuffix("-\(candidateTier)") {
            normalizedModel.removeLast(candidateTier.count + 1)
            tier = candidateTier
            break
        }

        let canonicalModel = aliases[normalizedModel] ?? normalizedModel
        guard let rule = rules[canonicalModel]?.first(where: { rule in
            let isAfterStart = rule.effectiveFrom.map { date >= $0 } ?? true
            let isBeforeEnd = rule.effectiveUntil.map { date < $0 } ?? true
            return isAfterStart && isBeforeEnd
        }) else { return nil }
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
    static let officialAPI = PricingCatalog(
        version: "official-api-2026-08-07-v1",
        verifiedAt: Date(timeIntervalSince1970: 1_786_060_800),
        sourceURLs: [
            "https://developers.openai.com/api/docs/pricing/",
            "https://platform.claude.com/docs/en/about-claude/pricing",
            "https://ai.google.dev/gemini-api/docs/pricing"
        ],
        rules: [
            // OpenAI / Codex. Long-context premiums are not applied to aggregated local usage.
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
            rule("codex-mini-latest", 1_500_000, 6_000_000, 375_000),

            // Anthropic. Cache creation uses the normal input-rate estimate.
            rule("claude-fable-5", 10_000_000, 50_000_000, 1_000_000),
            rule("claude-mythos-5", 10_000_000, 50_000_000, 1_000_000),
            rule("claude-opus-5", 5_000_000, 25_000_000, 500_000),
            rule("claude-opus-4-8", 5_000_000, 25_000_000, 500_000),
            rule("claude-opus-4-7", 5_000_000, 25_000_000, 500_000),
            rule("claude-opus-4-6", 5_000_000, 25_000_000, 500_000),
            rule("claude-opus-4-5", 5_000_000, 25_000_000, 500_000),
            rule("claude-opus-4-1", 15_000_000, 75_000_000, 1_500_000),
            rule("claude-opus-4", 15_000_000, 75_000_000, 1_500_000),
            rule(
                "claude-sonnet-5",
                2_000_000,
                10_000_000,
                200_000,
                effectiveUntil: Date(timeIntervalSince1970: 1_788_220_800)
            ),
            rule(
                "claude-sonnet-5",
                3_000_000,
                15_000_000,
                300_000,
                effectiveFrom: Date(timeIntervalSince1970: 1_788_220_800)
            ),
            rule("claude-sonnet-4-6", 3_000_000, 15_000_000, 300_000),
            rule("claude-sonnet-4-5", 3_000_000, 15_000_000, 300_000),
            rule("claude-sonnet-4", 3_000_000, 15_000_000, 300_000),
            rule("claude-haiku-4-5", 1_000_000, 5_000_000, 100_000),
            rule("claude-haiku-3-5", 800_000, 4_000_000, 80_000),

            // Google Gemini. Text rates are used for coding-tool telemetry.
            rule("gemini-3-6-flash", 1_500_000, 7_500_000, 150_000),
            rule("gemini-3-5-flash", 1_500_000, 9_000_000, 150_000),
            rule("gemini-3-5-flash-lite", 300_000, 2_500_000, 30_000),
            rule("gemini-3-1-pro-preview", 2_000_000, 12_000_000, 200_000),
            rule("gemini-3-1-flash-lite", 250_000, 1_500_000, 25_000),
            rule("gemini-3-flash-preview", 500_000, 3_000_000, 50_000),
            rule("gemini-2-5-pro", 1_250_000, 10_000_000, 125_000),
            rule("gemini-2-5-flash", 300_000, 2_500_000, 30_000),
            rule("gemini-2-5-flash-lite", 100_000, 400_000, 10_000),
            rule("gemini-2-0-flash", 100_000, 400_000, 25_000),
            rule("gemini-2-0-flash-lite", 75_000, 300_000, nil)
        ],
        aliases: [
            "gpt-5.6": "gpt-5.6-sol",
            "gpt-5-6": "gpt-5.6-sol",
            "gpt-5-6-sol": "gpt-5.6-sol",
            "gpt-5-6-terra": "gpt-5.6-terra",
            "gpt-5-6-luna": "gpt-5.6-luna",
            "claude-opus-4.8": "claude-opus-4-8",
            "claude-opus-4.7": "claude-opus-4-7",
            "claude-opus-4.6": "claude-opus-4-6",
            "claude-opus-4.5": "claude-opus-4-5",
            "claude-opus-4.1": "claude-opus-4-1",
            "claude-sonnet-4.6": "claude-sonnet-4-6",
            "claude-sonnet-4.5": "claude-sonnet-4-5",
            "claude-haiku-4.5": "claude-haiku-4-5",
            "claude-haiku-3.5": "claude-haiku-3-5",
            "claude-opus-4-1-20250805": "claude-opus-4-1",
            "claude-opus-4-20250514": "claude-opus-4",
            "claude-opus-4-5-20251101": "claude-opus-4-5",
            "claude-sonnet-4-20250514": "claude-sonnet-4",
            "claude-sonnet-4-5-20250929": "claude-sonnet-4-5",
            "claude-haiku-4-5-20251001": "claude-haiku-4-5",
            "gemini-3.6-flash": "gemini-3-6-flash",
            "gemini-3.5-flash": "gemini-3-5-flash",
            "gemini-3.5-flash-lite": "gemini-3-5-flash-lite",
            "gemini-3.1-pro-preview": "gemini-3-1-pro-preview",
            "gemini-3.1-pro-preview-customtools": "gemini-3-1-pro-preview",
            "gemini-3.1-flash-lite": "gemini-3-1-flash-lite",
            "gemini-2.5-pro": "gemini-2-5-pro",
            "gemini-2.5-flash": "gemini-2-5-flash",
            "gemini-2.5-flash-lite": "gemini-2-5-flash-lite",
            "gemini-2.5-flash-lite-preview-09-2025": "gemini-2-5-flash-lite",
            "gemini-2.0-flash": "gemini-2-0-flash",
            "gemini-2.0-flash-lite": "gemini-2-0-flash-lite"
        ]
    )

    private static func rule(
        _ model: String,
        _ input: Int64,
        _ output: Int64,
        _ cachedInput: Int64?,
        tiers: [String: TokenPriceRate] = [:],
        effectiveFrom: Date? = nil,
        effectiveUntil: Date? = nil
    ) -> ModelPricingRule {
        ModelPricingRule(
            canonicalModel: model,
            standardRate: rate(input, output, cachedInput),
            tierRates: tiers,
            effectiveFrom: effectiveFrom,
            effectiveUntil: effectiveUntil
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

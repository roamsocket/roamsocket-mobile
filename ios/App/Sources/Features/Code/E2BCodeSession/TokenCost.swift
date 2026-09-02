import Foundation

/// Pricing + cost estimate for the Anthropic models the E2B
/// session runner uses. Prices are USD per 1M tokens.
///
/// v1: hardcoded for Claude Sonnet 4.5. When Anthropic changes
/// pricing, update `pricingFor(modelID:)` and the totals refresh
/// the next time the user opens the chat. The estimate is shown
/// to the user as "running cost" — not billed, just transparent.
public enum TokenCost {
    /// USD per 1M tokens, by model id. Cached read input is
    /// cheaper than fresh input; cache creation has its own
    /// surcharge.
    public struct Rate: Hashable, Sendable {
        public let inputPerMTok: Double
        public let outputPerMTok: Double
        public let cacheReadPerMTok: Double?
        public let cacheWritePerMTok: Double?
    }

    public static let defaultRates: [String: Rate] = [
        "claude-sonnet-4-5": .init(
            inputPerMTok: 3.0,
            outputPerMTok: 15.0,
            cacheReadPerMTok: 0.30,
            cacheWritePerMTok: 3.75
        ),
        "claude-sonnet-4": .init(
            inputPerMTok: 3.0,
            outputPerMTok: 15.0,
            cacheReadPerMTok: 0.30,
            cacheWritePerMTok: 3.75
        ),
        "claude-3-5-sonnet-latest": .init(
            inputPerMTok: 3.0,
            outputPerMTok: 15.0,
            cacheReadPerMTok: 0.30,
            cacheWritePerMTok: 3.75
        ),
    ]

    public static func pricingFor(modelID: String) -> Rate {
        if let exact = defaultRates[modelID] { return exact }
        // Prefix match for dated snapshots like
        // "claude-sonnet-4-5-20250901".
        for (key, rate) in defaultRates {
            if modelID.hasPrefix(key) { return rate }
        }
        return defaultRates["claude-sonnet-4-5"]!
    }

    /// Cost in USD for the given token usage at the given rate.
    /// Provider-agnostic: takes primitives so callers don't have
    /// to depend on a specific LLM client type.
    public static func costUSD(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        rate: Rate,
    ) -> Double {
        let inputCost = Double(inputTokens) / 1_000_000.0 * rate.inputPerMTok
        let outputCost = Double(outputTokens) / 1_000_000.0 * rate.outputPerMTok
        var cacheCost = 0.0
        if let cacheRead = cacheReadTokens, let r = rate.cacheReadPerMTok {
            cacheCost += Double(cacheRead) / 1_000_000.0 * r
        }
        if let cacheWrite = cacheWriteTokens, let r = rate.cacheWritePerMTok {
            cacheCost += Double(cacheWrite) / 1_000_000.0 * r
        }
        return inputCost + outputCost + cacheCost
    }

    /// Compact rendering for the running cost in the chat footer.
    public static func formatUSD(_ value: Double) -> String {
        if value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }
}

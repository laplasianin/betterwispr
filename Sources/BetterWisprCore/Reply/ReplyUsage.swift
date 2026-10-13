import Foundation

/// Token counts one reply request reported, and what they cost at the model's list price.
public struct ReplyUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
    }

    public static func + (lhs: ReplyUsage, rhs: ReplyUsage) -> ReplyUsage {
        ReplyUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
                   cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }

    /// US dollars at the model's list price.
    public func cost(for model: ClaudeModel) -> Double {
        let price = model.pricePerMillionTokens
        return (Double(inputTokens) * price.input + Double(cacheReadTokens) * price.cacheRead
                + Double(cacheWriteTokens) * price.cacheWrite + Double(outputTokens) * price.output) / 1_000_000
    }

    /// "$0.006", "$0.12", or "<$0.001" for amounts too small to show.
    public static func label(_ dollars: Double) -> String {
        if dollars < 0.0005 { return "<$0.001" }
        if dollars < 0.01 { return String(format: "$%.3f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}

extension ClaudeModel {
    /// Anthropic list prices in US dollars per million tokens, October 2026; a cache write costs 1.25× the input price.
    public var pricePerMillionTokens: (input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        switch self {
        case .opus: (4, 20, 0.20, 5)
        case .sonnet: (2, 10, 0.20, 2.5)
        case .haiku: (0.10, 0.50, 0.01, 0.125)
        }
    }
}

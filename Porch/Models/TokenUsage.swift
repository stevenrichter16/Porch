import Foundation

struct TokenUsage: Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int

    var totalTokens: Int { promptTokens + completionTokens }

    var formattedTotal: String {
        Self.formatTokenCount(totalTokens)
    }

    var formattedPrompt: String {
        Self.formatTokenCount(promptTokens)
    }

    var formattedCompletion: String {
        Self.formatTokenCount(completionTokens)
    }

    static func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: "%.1fK", k)
        }
        return "\(count)"
    }
}

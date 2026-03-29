import Foundation

enum ChatStreamEvent: Equatable {
    case token(String)
    case toolCalls([ToolCall])
    case usage(TokenUsage)
    case completed(ChatFinishReason?)
}

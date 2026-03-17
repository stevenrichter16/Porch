import Foundation

enum ChatStreamEvent: Equatable {
    case token(String)
    case completed(ChatFinishReason?)
}

import Foundation

enum ChatFinishReason: Codable, Equatable {
    case stop
    case length
    case contentFilter
    case toolCalls
    case cancelled
    case other(String)

    init(apiValue: String) {
        switch apiValue {
        case "stop":
            self = .stop
        case "length":
            self = .length
        case "content_filter":
            self = .contentFilter
        case "tool_calls":
            self = .toolCalls
        case "cancelled":
            self = .cancelled
        default:
            self = .other(apiValue)
        }
    }

    var apiValue: String {
        switch self {
        case .stop:
            "stop"
        case .length:
            "length"
        case .contentFilter:
            "content_filter"
        case .toolCalls:
            "tool_calls"
        case .cancelled:
            "cancelled"
        case .other(let value):
            value
        }
    }

    var userMessage: String? {
        switch self {
        case .length:
            "Response stopped because the max token limit was reached."
        default:
            nil
        }
    }
}

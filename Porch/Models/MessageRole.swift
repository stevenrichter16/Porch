import Foundation

enum MessageRole: String, Codable, CaseIterable, Identifiable {
    case system
    case user
    case assistant
    case tool

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            "System"
        case .user:
            "You"
        case .assistant:
            "Assistant"
        case .tool:
            "Tool"
        }
    }
}

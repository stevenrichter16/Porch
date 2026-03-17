import Foundation

enum MessageRole: String, Codable, CaseIterable, Identifiable {
    case system
    case user
    case assistant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            "System"
        case .user:
            "You"
        case .assistant:
            "Assistant"
        }
    }
}

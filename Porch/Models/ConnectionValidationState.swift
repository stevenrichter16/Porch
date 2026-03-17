import Foundation

enum ConnectionValidationState: String, Codable {
    case notValidated
    case validating
    case valid
    case invalid

    var statusText: String {
        switch self {
        case .notValidated:
            "Not validated"
        case .validating:
            "Validating..."
        case .valid:
            "Ready"
        case .invalid:
            "Needs attention"
        }
    }
}

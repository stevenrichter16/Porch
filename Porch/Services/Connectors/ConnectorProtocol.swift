import Foundation

protocol Connector: Sendable {
    var id: String { get }
    var displayName: String { get }
    var iconSystemName: String { get }
    var toolDefinitions: [ToolDefinition] { get }
    var isConfigured: Bool { get }

    func execute(toolName: String, arguments: String) async throws -> String
}

enum ConnectorError: LocalizedError {
    case unknownTool(String)
    case invalidArguments(String)
    case apiError(String)
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "Unknown tool: \(name)"
        case .invalidArguments(let detail):
            "Invalid arguments: \(detail)"
        case .apiError(let detail):
            "API error: \(detail)"
        case .notConfigured(let connector):
            "\(connector) is not configured."
        }
    }
}

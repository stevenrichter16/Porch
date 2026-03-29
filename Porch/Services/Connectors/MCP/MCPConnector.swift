import Foundation

/// A connector that dynamically discovers and exposes tools from an MCP server.
/// Each MCPConnector instance connects to one MCP server URL and translates
/// its tools into Porch's ToolDefinition format.
final class MCPConnector: Connector, @unchecked Sendable {
    private static let logger = PorchLogger(category: "MCPConnector")

    let id: String
    let displayName: String
    let iconSystemName = "server.rack"

    private let serverURL: URL
    private let headers: [String: String]
    private let client: MCPClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var discoveredTools: [MCPClient.MCPToolInfo] = []
    private var cachedToolDefinitions: [ToolDefinition] = []
    private var isDiscovered = false

    init(
        serverURL: URL,
        displayName: String? = nil,
        headers: [String: String] = [:],
        client: MCPClient = MCPClient()
    ) {
        self.serverURL = serverURL
        self.displayName = displayName ?? serverURL.host ?? "MCP Server"
        self.id = "mcp_\(serverURL.host ?? "unknown")"
        self.headers = headers
        self.client = client
    }

    var isConfigured: Bool { true }

    var toolDefinitions: [ToolDefinition] {
        cachedToolDefinitions
    }

    /// Discover available tools from the MCP server. Must be called before tools can be used.
    func discoverTools() async throws {
        Self.logger.info("[discover] server=\(serverURL.absoluteString)")
        discoveredTools = try await client.listTools(serverURL: serverURL, headers: headers)
        cachedToolDefinitions = discoveredTools.map(convertToToolDefinition)
        isDiscovered = true
        Self.logger.info("[discover] found \(discoveredTools.count) tools: \(discoveredTools.map(\.name).joined(separator: ", "))")
    }

    func execute(toolName: String, arguments: String) async throws -> String {
        guard discoveredTools.contains(where: { $0.name == toolName }) else {
            throw ConnectorError.unknownTool(toolName)
        }

        // Parse arguments JSON into dictionary
        let argsDict: [String: AnyCodable]
        let argsData = Data(arguments.utf8)
        if let decoded = try? decoder.decode([String: AnyCodable].self, from: argsData) {
            argsDict = decoded
        } else {
            argsDict = [:]
        }

        return try await client.callTool(
            serverURL: serverURL,
            name: toolName,
            arguments: argsDict,
            headers: headers
        )
    }

    // MARK: - Private

    private func convertToToolDefinition(_ mcpTool: MCPClient.MCPToolInfo) -> ToolDefinition {
        // Convert MCP input schema to our JSONSchemaValue format
        let parameters: JSONSchemaValue
        if let schema = mcpTool.inputSchema {
            parameters = convertAnyCodableToSchema(schema)
        } else {
            parameters = .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ])
        }

        return ToolDefinition(function: FunctionDefinitionBody(
            name: mcpTool.name,
            description: mcpTool.description ?? "MCP tool: \(mcpTool.name)",
            parameters: parameters
        ))
    }

    private func convertAnyCodableToSchema(_ value: AnyCodable) -> JSONSchemaValue {
        switch value.value {
        case let string as String:
            return .string(string)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            return .array(array.map { convertAnyCodableToSchema(AnyCodable($0)) })
        case let dict as [String: Any]:
            var result: [String: JSONSchemaValue] = [:]
            for (key, val) in dict {
                result[key] = convertAnyCodableToSchema(AnyCodable(val))
            }
            return .object(result)
        default:
            return .null
        }
    }
}

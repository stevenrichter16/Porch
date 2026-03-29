import Foundation

/// Lightweight MCP (Model Context Protocol) client using streamable HTTP transport.
/// Communicates with MCP servers via JSON-RPC over HTTP POST.
actor MCPClient {
    private static let logger = PorchLogger(category: "MCP")

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - JSON-RPC Types

    struct JSONRPCRequest: Encodable {
        var jsonrpc: String = "2.0"
        var id: Int
        var method: String
        var params: [String: AnyCodable]?
    }

    struct JSONRPCResponse: Decodable {
        var jsonrpc: String
        var id: Int?
        var result: AnyCodable?
        var error: JSONRPCError?
    }

    struct JSONRPCError: Decodable, LocalizedError {
        var code: Int
        var message: String

        var errorDescription: String? { message }
    }

    // MARK: - MCP Tool Types

    struct MCPToolInfo: Decodable {
        var name: String
        var description: String?
        var inputSchema: AnyCodable?
    }

    struct MCPToolListResult: Decodable {
        var tools: [MCPToolInfo]
    }

    struct MCPToolCallResult: Decodable {
        var content: [MCPContent]?
        var isError: Bool?
    }

    struct MCPContent: Decodable {
        var type: String
        var text: String?
    }

    // MARK: - Public API

    func listTools(serverURL: URL, headers: [String: String] = [:]) async throws -> [MCPToolInfo] {
        Self.logger.info("[listTools] server=\(serverURL.absoluteString)")

        let response = try await sendRequest(
            to: serverURL,
            method: "tools/list",
            params: nil,
            headers: headers,
            requestID: 1
        )

        if let error = response.error {
            throw error
        }

        guard let resultData = response.result else {
            return []
        }

        let jsonData = try encoder.encode(resultData)
        let result = try decoder.decode(MCPToolListResult.self, from: jsonData)
        Self.logger.info("[listTools] found \(result.tools.count) tools")
        return result.tools
    }

    func callTool(
        serverURL: URL,
        name: String,
        arguments: [String: AnyCodable],
        headers: [String: String] = [:]
    ) async throws -> String {
        Self.logger.info("[callTool] tool=\(name) server=\(serverURL.absoluteString)")

        let response = try await sendRequest(
            to: serverURL,
            method: "tools/call",
            params: [
                "name": AnyCodable(name),
                "arguments": AnyCodable(arguments)
            ],
            headers: headers,
            requestID: 2
        )

        if let error = response.error {
            throw error
        }

        guard let resultData = response.result else {
            return "{}"
        }

        let jsonData = try encoder.encode(resultData)
        let result = try decoder.decode(MCPToolCallResult.self, from: jsonData)

        // Concatenate all text content
        let text = result.content?
            .compactMap(\.text)
            .joined(separator: "\n") ?? "{}"

        Self.logger.info("[callTool] tool=\(name) resultLength=\(text.count) isError=\(result.isError ?? false)")
        return text
    }

    // MARK: - Private

    private func sendRequest(
        to serverURL: URL,
        method: String,
        params: [String: AnyCodable]?,
        headers: [String: String],
        requestID: Int
    ) async throws -> JSONRPCResponse {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let rpcRequest = JSONRPCRequest(
            id: requestID,
            method: method,
            params: params
        )
        request.httpBody = try encoder.encode(rpcRequest)

        let (data, urlResponse) = try await session.data(for: request)

        if let httpResponse = urlResponse as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error("[request] method=\(method) status=\(httpResponse.statusCode) body=\(body.prefix(500))")
            throw ConnectorError.apiError("MCP server returned HTTP \(httpResponse.statusCode)")
        }

        return try decoder.decode(JSONRPCResponse.self, from: data)
    }
}

/// A type-erased Codable wrapper for arbitrary JSON values.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyCodable.init))
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Simplified equality — compare encoded JSON
        let encoder = JSONEncoder()
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else {
            return false
        }
        return lhsData == rhsData
    }
}

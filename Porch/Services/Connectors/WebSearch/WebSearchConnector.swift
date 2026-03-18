import Foundation

final class WebSearchConnector: Connector, @unchecked Sendable {
    let id = "web_search"
    let displayName = "Web Search"
    let iconSystemName = "globe"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // No API key needed — uses DuckDuckGo HTML
    var isConfigured: Bool { true }

    // MARK: - Tool Definitions

    var toolDefinitions: [ToolDefinition] {
        [searchWebTool, fetchPageTool]
    }

    // MARK: - Execution

    func execute(toolName: String, arguments: String) async throws -> String {
        let client = DuckDuckGoClient()
        let argsData = Data(arguments.utf8)

        switch toolName {
        case "web_search":
            return try await executeSearch(client: client, argsData: argsData)
        case "web_fetch_page":
            return try await executeFetchPage(client: client, argsData: argsData)
        default:
            throw ConnectorError.unknownTool(toolName)
        }
    }

    // MARK: - Tool Implementations

    private func executeSearch(client: DuckDuckGoClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var query: String; var max_results: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let results = try await client.search(query: args.query, maxResults: args.max_results ?? 8)
        return try encodeResult(["results": results])
    }

    private func executeFetchPage(client: DuckDuckGoClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var url: String; var max_length: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let content = try await client.fetchPageContent(url: args.url, maxLength: args.max_length ?? 15000)
        return try encodeResult(["url": args.url, "content": content])
    }

    // MARK: - Helpers

    private func decodeArgs<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ConnectorError.invalidArguments(error.localizedDescription)
        }
    }

    private func encodeResult<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Tool Definitions

    private var searchWebTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "web_search",
            description: "Search the web using DuckDuckGo. Returns titles, URLs, and snippets for matching pages. Use this to find current information, look up facts, or find relevant websites.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The search query")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of results to return (default 8, max 15)")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ))
    }

    private var fetchPageTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "web_fetch_page",
            description: "Fetch and read the text content of a web page. Use this after web_search to read the full content of a specific result. Returns the page's readable text with HTML stripped.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The full URL of the page to fetch")
                    ]),
                    "max_length": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum character length of returned content (default 15000)")
                    ])
                ]),
                "required": .array([.string("url")])
            ])
        ))
    }
}

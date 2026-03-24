import Foundation

final class WebSearchConnector: Connector, @unchecked Sendable {
    private static let logger = PorchLogger(category: "WebSearch")
    let id = "web_search"
    let displayName = "Web Search"
    let iconSystemName = "globe"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let client: DuckDuckGoClient

    init(session: URLSession = .shared) {
        self.client = DuckDuckGoClient(session: session)
    }

    var isConfigured: Bool { true }

    var toolDefinitions: [ToolDefinition] {
        [searchWebTool, fetchPageTool]
    }

    func execute(toolName: String, arguments: String) async throws -> String {
        Self.logger.info("[exec] tool=\(toolName)")
        let argsData = Data(arguments.utf8)

        do {
            let result: String
            switch toolName {
            case "web_search":
                result = try await executeSearch(argsData: argsData)
            case "web_fetch_page":
                result = try await executeFetchPage(argsData: argsData)
            default:
                throw ConnectorError.unknownTool(toolName)
            }
            Self.logger.info("[exec] tool=\(toolName) resultLength=\(result.count)")
            return result
        } catch {
            Self.logger.error("[exec] tool=\(toolName) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func executeSearch(argsData: Data) async throws -> String {
        struct Args: Decodable {
            var query: String
            var max_results: Int?
        }

        struct SearchResultsPayload: Encodable {
            var results: [DuckDuckGoClient.SearchResult]
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let results = try await client.search(query: args.query, maxResults: args.max_results ?? 8)
        return try encodeResult(SearchResultsPayload(results: results))
    }

    private func executeFetchPage(argsData: Data) async throws -> String {
        struct Args: Decodable {
            var url: String
            var max_length: Int?
        }

        struct PagePayload: Encodable {
            var url: String
            var content: String
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let content = try await client.fetchPageContent(url: args.url, maxLength: args.max_length ?? 15_000)
        return try encodeResult(PagePayload(url: args.url, content: content))
    }

    private func decodeArgs<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ConnectorError.invalidArguments(error.localizedDescription)
        }
    }

    private func encodeResult<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private var searchWebTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "web_search",
            description: "Search the web using DuckDuckGo. Returns titles, URLs, and snippets for matching pages. Use this to find current information, look up facts, or find relevant websites.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The search query.")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of results to return (default 8, max 15).")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ))
    }

    private var fetchPageTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "web_fetch_page",
            description: "Fetch and read the text content of a web page. Use this after web_search to read the full content of a specific result.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The full URL of the page to fetch.")
                    ]),
                    "max_length": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum character length of returned content (default 15000).")
                    ])
                ]),
                "required": .array([.string("url")])
            ])
        ))
    }
}

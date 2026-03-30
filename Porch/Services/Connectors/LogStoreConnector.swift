import Foundation

/// Exposes the in-memory log ring buffer as a tool the LLM can call
/// to inspect its own recent behavior, errors, and timing.
final class LogStoreConnector: Connector, @unchecked Sendable {
    let id = "log_store"
    let displayName = "Logs"
    let iconSystemName = "doc.text.magnifyingglass"

    private let store: LogStore
    private let encoder = JSONEncoder()

    init(store: LogStore = .shared) {
        self.store = store
    }

    var isConfigured: Bool { true }

    var toolDefinitions: [ToolDefinition] {
        [getRecentLogsTool]
    }

    func execute(toolName: String, arguments: String) async throws -> String {
        guard toolName == "get_recent_logs" else {
            throw ConnectorError.unknownTool(toolName)
        }

        struct Args: Decodable {
            var count: Int?
            var level: String?
            var category: String?
        }

        let args: Args
        let data = Data(arguments.utf8)
        if let decoded = try? JSONDecoder().decode(Args.self, from: data) {
            args = decoded
        } else {
            args = Args()
        }

        let maxCount = min(args.count ?? 50, 200)
        let entries = store.recentEntries(
            count: maxCount,
            level: args.level,
            category: args.category
        )

        struct Response: Encodable {
            var entry_count: Int
            var entries: [LogStore.Entry]
        }

        let response = Response(entry_count: entries.count, entries: entries)
        let json = try encoder.encode(response)
        return String(decoding: json, as: UTF8.self)
    }

    private var getRecentLogsTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "get_recent_logs",
            description: "Read recent application logs to understand what happened during tool calls, API requests, and errors. Use this to diagnose failures, inspect timing, and understand why previous operations succeeded or failed. Logs include HTTP status codes, tool call arguments, streaming durations, and save errors.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "count": .object([
                        "type": .string("integer"),
                        "description": .string("Number of recent log entries to return (default 50, max 200).")
                    ]),
                    "level": .object([
                        "type": .string("string"),
                        "description": .string("Filter by log level: debug, info, notice, error, fault. Returns all levels if omitted."),
                        "enum": .array([.string("debug"), .string("info"), .string("notice"), .string("error"), .string("fault")])
                    ]),
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("Filter by category: ChatViewModel, API, GitHub, GitHubConnector, WebSearch, DuckDuckGo, SSEParser, ToolParser, Settings, Keychain, GitHubContext, App.")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }
}

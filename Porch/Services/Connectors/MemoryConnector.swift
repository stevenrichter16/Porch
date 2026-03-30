import Foundation
import SwiftData

/// Exposes a persistent memory system as tools the LLM can call
/// to remember facts about the user across conversations.
final class MemoryConnector: Connector, @unchecked Sendable {
    let id = "memory"
    let displayName = "Memory"
    let iconSystemName = "brain"

    private let modelContainer: ModelContainer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var isConfigured: Bool { true }

    var toolDefinitions: [ToolDefinition] {
        [saveMemoryTool, recallMemoriesTool]
    }

    func execute(toolName: String, arguments: String) async throws -> String {
        let argsData = Data(arguments.utf8)

        switch toolName {
        case "save_memory":
            return try await executeSaveMemory(argsData: argsData)
        case "recall_memories":
            return try await executeRecallMemories(argsData: argsData)
        default:
            throw ConnectorError.unknownTool(toolName)
        }
    }

    /// Returns a system prompt snippet with the user's stored memories.
    func memoryContextSnippet(limit: Int = 20) async -> String? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<MemoryEntry>(
            sortBy: [SortDescriptor(\MemoryEntry.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        guard let memories = try? context.fetch(descriptor), !memories.isEmpty else {
            return nil
        }

        var lines: [String] = ["The following are facts you have previously remembered about the user:"]
        for memory in memories {
            lines.append("- [\(memory.category)] \(memory.key): \(memory.content)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tool Execution

    private func executeSaveMemory(argsData: Data) async throws -> String {
        struct Args: Decodable {
            var key: String
            var content: String
            var category: String?
        }

        let args = try decodeArgs(Args.self, from: argsData)

        guard !args.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorError.invalidArguments("Memory key cannot be empty")
        }

        let context = ModelContext(modelContainer)

        // Upsert: check if a memory with this key exists
        let key = args.key
        var descriptor = FetchDescriptor<MemoryEntry>(
            predicate: #Predicate<MemoryEntry> { entry in
                entry.key == key
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.content = args.content
            existing.category = args.category ?? existing.category
            existing.updatedAt = .now
        } else {
            let entry = MemoryEntry(
                key: args.key,
                content: args.content,
                category: args.category ?? "general"
            )
            context.insert(entry)
        }

        try context.save()

        struct Response: Encodable {
            var status: String
            var key: String
        }

        return try encodeResult(Response(status: "saved", key: args.key))
    }

    private func executeRecallMemories(argsData: Data) async throws -> String {
        struct Args: Decodable {
            var query: String?
            var category: String?
            var limit: Int?
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let context = ModelContext(modelContainer)
        let maxResults = min(args.limit ?? 20, 50)

        var descriptor = FetchDescriptor<MemoryEntry>(
            sortBy: [SortDescriptor(\MemoryEntry.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = maxResults

        // Apply category filter if provided
        if let category = args.category {
            descriptor.predicate = #Predicate<MemoryEntry> { entry in
                entry.category == category
            }
        }

        let memories = try context.fetch(descriptor)

        // Apply query filter in-memory (simple substring match)
        let filtered: [MemoryEntry]
        if let query = args.query?.lowercased(), !query.isEmpty {
            filtered = memories.filter {
                $0.key.lowercased().contains(query)
                || $0.content.lowercased().contains(query)
            }
        } else {
            filtered = memories
        }

        struct MemoryResult: Encodable {
            var key: String
            var content: String
            var category: String
            var updated_at: String
        }

        struct Response: Encodable {
            var count: Int
            var memories: [MemoryResult]
        }

        let formatter = ISO8601DateFormatter()
        let results = filtered.map { entry in
            MemoryResult(
                key: entry.key,
                content: entry.content,
                category: entry.category,
                updated_at: formatter.string(from: entry.updatedAt)
            )
        }

        return try encodeResult(Response(count: results.count, memories: results))
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
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tool Definitions

    private var saveMemoryTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "save_memory",
            description: "Save a fact or preference about the user that should persist across conversations. Use this when the user tells you something important about themselves, their preferences, their project, or asks you to remember something.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "key": .object([
                        "type": .string("string"),
                        "description": .string("A short, unique identifier for this memory (e.g. 'preferred_language', 'project_name', 'timezone'). If a memory with this key already exists, it will be updated.")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The content to remember.")
                    ]),
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("Category: 'preference', 'fact', 'instruction', or 'general'."),
                        "enum": .array([.string("preference"), .string("fact"), .string("instruction"), .string("general")])
                    ])
                ]),
                "required": .array([.string("key"), .string("content")])
            ])
        ))
    }

    private var recallMemoriesTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "recall_memories",
            description: "Search your stored memories about the user. Use this to recall user preferences, facts, or instructions from previous conversations.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional search query to filter memories by keyword.")
                    ]),
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("Optional category filter."),
                        "enum": .array([.string("preference"), .string("fact"), .string("instruction"), .string("general")])
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of memories to return (default 20, max 50).")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }
}

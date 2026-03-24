import Foundation

// MARK: - Tool Calling Types

struct ToolCall: Codable, Equatable {
    var id: String
    var type: String
    var function: FunctionCall

    init(id: String, type: String = "function", function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

struct FunctionCall: Codable, Equatable {
    var name: String
    var arguments: String
}

struct ToolDefinition: Encodable {
    var type: String = "function"
    var function: FunctionDefinitionBody
}

struct FunctionDefinitionBody: Encodable {
    var name: String
    var description: String
    var parameters: JSONSchemaValue

    init(name: String, description: String, parameters: JSONSchemaValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A lightweight JSON value type for encoding JSON Schema objects.
enum JSONSchemaValue: Encodable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONSchemaValue])
    case object([String: JSONSchemaValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

struct StreamingToolCallDelta: Decodable {
    var index: Int?
    var id: String?
    var type: String?
    var function: StreamingFunctionDelta?
}

struct StreamingFunctionDelta: Decodable {
    var name: String?
    var arguments: String?
}

// MARK: - Chat Messages

struct OpenAIChatMessage: Codable, Equatable {
    var role: String
    var content: String?
    var tool_calls: [ToolCall]?
    var tool_call_id: String?
    var name: String?

    init(role: String, content: String?) {
        self.role = role
        self.content = content
    }

    init(role: String, content: String?, toolCalls: [ToolCall]) {
        self.role = role
        self.content = content
        self.tool_calls = toolCalls
    }

    init(role: String, content: String?, toolCallID: String, name: String) {
        self.role = role
        self.content = content
        self.tool_call_id = toolCallID
        self.name = name
    }
}

// MARK: - Request/Response Bodies

struct OpenAIChatRequestDescriptor: Equatable {
    var configuration: ServerConfiguration
    var modelID: String
    var messages: [OpenAIChatMessage]
    var parameters: GenerationParameters
    var tools: [ToolDefinition]?
    var toolChoice: ChatCompletionToolChoice?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration &&
        lhs.modelID == rhs.modelID &&
        lhs.messages == rhs.messages &&
        lhs.parameters == rhs.parameters &&
        lhs.toolChoice == rhs.toolChoice
    }
}

enum ChatCompletionToolChoice: Encodable, Equatable {
    case none

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode("none")
        }
    }
}

struct ChatCompletionRequestBody: Encodable {
    var model: String
    var messages: [OpenAIChatMessage]
    var stream: Bool
    var temperature: Double
    var max_tokens: Int
    var top_p: Double
    var frequency_penalty: Double
    var presence_penalty: Double
    var stop: [String]?
    var tools: [ToolDefinition]?
    var tool_choice: ChatCompletionToolChoice?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, max_tokens, top_p
        case frequency_penalty, presence_penalty, stop, tools, tool_choice
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(max_tokens, forKey: .max_tokens)
        try container.encode(top_p, forKey: .top_p)
        try container.encode(frequency_penalty, forKey: .frequency_penalty)
        try container.encode(presence_penalty, forKey: .presence_penalty)
        try container.encodeIfPresent(stop, forKey: .stop)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(tool_choice, forKey: .tool_choice)
    }
}

struct ModelsResponseBody: Decodable {
    struct ModelObject: Decodable {
        var id: String
        var owned_by: String?
    }

    var data: [ModelObject]
}

struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var role: String?
            var content: String?
            var tool_calls: [StreamingToolCallDelta]?
        }

        var index: Int
        var delta: Delta
        var finish_reason: String?
    }

    var choices: [Choice]
}

struct ChatCompletionResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var role: String
            var content: String?
            var tool_calls: [ToolCall]?
        }

        var index: Int
        var message: Message
        var finish_reason: String?
    }

    var choices: [Choice]
}

struct NonStreamingCompletionResult {
    var content: String?
    var toolCalls: [ToolCall]?
    var finishReason: ChatFinishReason?
}

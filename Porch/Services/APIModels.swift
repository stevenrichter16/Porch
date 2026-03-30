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

/// Content part for multimodal messages (text + images).
struct ContentPart: Codable, Equatable {
    var type: String
    var text: String?
    var image_url: ImageURL?

    struct ImageURL: Codable, Equatable {
        var url: String
    }

    static func text(_ text: String) -> ContentPart {
        ContentPart(type: "text", text: text)
    }

    static func imageURL(_ dataURL: String) -> ContentPart {
        ContentPart(type: "image_url", image_url: ImageURL(url: dataURL))
    }
}

struct OpenAIChatMessage: Codable, Equatable {
    var role: String
    var content: String?
    var contentParts: [ContentPart]?
    var tool_calls: [ToolCall]?
    var tool_call_id: String?
    var name: String?

    init(role: String, content: String?) {
        self.role = role
        self.content = content
    }

    init(role: String, contentParts: [ContentPart]) {
        self.role = role
        self.contentParts = contentParts
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

    enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, name
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if let parts = contentParts {
            // Encode content as array of parts for vision API
            try container.encode(parts, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }

        try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        try container.encodeIfPresent(name, forKey: .name)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)

        // content can be either a plain string or an array of ContentParts (vision API)
        if let parts = try? container.decode([ContentPart].self, forKey: .content) {
            contentParts = parts
            content = parts.compactMap(\.text).joined()
        } else {
            content = try container.decodeIfPresent(String.self, forKey: .content)
            contentParts = nil
        }

        tool_calls = try container.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
        tool_call_id = try container.decodeIfPresent(String.self, forKey: .tool_call_id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    static func == (lhs: OpenAIChatMessage, rhs: OpenAIChatMessage) -> Bool {
        lhs.role == rhs.role && lhs.content == rhs.content && lhs.tool_calls == rhs.tool_calls
        && lhs.tool_call_id == rhs.tool_call_id && lhs.name == rhs.name
        && lhs.contentParts == rhs.contentParts
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

struct APIUsage: Decodable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?

    var asTokenUsage: TokenUsage? {
        guard let prompt = prompt_tokens, let completion = completion_tokens else {
            return nil
        }
        return TokenUsage(promptTokens: prompt, completionTokens: completion)
    }
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
    var usage: APIUsage?
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
    var usage: APIUsage?
}

struct NonStreamingCompletionResult {
    var content: String?
    var toolCalls: [ToolCall]?
    var finishReason: ChatFinishReason?
    var usage: TokenUsage?
}

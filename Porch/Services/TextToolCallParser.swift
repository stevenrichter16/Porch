import Foundation

/// Parses tool calls from LLM text output for models that don't support
/// structured OpenAI-style `tool_calls` responses.
///
/// Recognizes two formats:
///
/// 1. Delimited blocks:
///    ```
///    <tool_call>
///    {"name": "tool_name", "arguments": {"key": "value"}}
///    </tool_call>
///    ```
///
/// 2. Fenced JSON blocks with a tool_call marker:
///    ```tool_call
///    {"name": "tool_name", "arguments": {"key": "value"}}
///    ```
///
enum TextToolCallParser {

    struct ParsedToolCall: Equatable {
        var name: String
        var arguments: String
    }

    struct ParseResult: Equatable {
        /// Tool calls extracted from the text.
        var toolCalls: [ParsedToolCall]
        /// The text with tool call blocks removed (the "spoken" content).
        var remainingText: String
    }

    /// Attempt to extract tool calls from model text output.
    /// Returns an empty array if no tool calls are found.
    static func parse(_ text: String) -> ParseResult {
        var toolCalls: [ParsedToolCall] = []
        var remaining = text

        // Pattern 1: <tool_call>...</tool_call>
        let xmlPattern = #/<tool_call>\s*\n?([\s\S]*?)\n?\s*</tool_call>/#
        for match in text.matches(of: xmlPattern) {
            let jsonString = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parseToolCallJSON(jsonString) {
                toolCalls.append(parsed)
            }
        }
        remaining = remaining.replacing(xmlPattern, with: "")

        // Pattern 2: ```tool_call\n...\n```
        let fencedPattern = #/```tool_call\s*\n([\s\S]*?)\n\s*```/#
        for match in text.matches(of: fencedPattern) {
            let jsonString = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parseToolCallJSON(jsonString) {
                toolCalls.append(parsed)
            }
        }
        remaining = remaining.replacing(fencedPattern, with: "")

        // Deduplicate (in case both patterns matched the same content)
        var seen = Set<String>()
        toolCalls = toolCalls.filter { call in
            let key = "\(call.name)|\(call.arguments)"
            return seen.insert(key).inserted
        }

        let cleanedRemaining = remaining
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParseResult(toolCalls: toolCalls, remainingText: cleanedRemaining)
    }

    // MARK: - Private

    private struct ToolCallJSON: Decodable {
        var name: String
        var arguments: AnyCodableArguments?

        enum CodingKeys: String, CodingKey {
            case name
            case arguments
        }
    }

    /// Flexible wrapper that accepts arguments as either a JSON object or a pre-encoded string.
    private enum AnyCodableArguments: Decodable {
        case string(String)
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                self = .string(str)
            } else if let obj = try? container.decode([String: JSONValue].self) {
                self = .object(obj)
            } else {
                throw DecodingError.typeMismatch(
                    AnyCodableArguments.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected string or object")
                )
            }
        }

        var jsonString: String {
            switch self {
            case .string(let str):
                return str
            case .object(let dict):
                let data = (try? JSONEncoder().encode(dict)) ?? Data()
                return String(data: data, encoding: .utf8) ?? "{}"
            }
        }
    }

    /// Minimal JSON value type for re-encoding arguments.
    private enum JSONValue: Codable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let val = try? container.decode(Bool.self) {
                self = .bool(val)
            } else if let val = try? container.decode(Int.self) {
                self = .int(val)
            } else if let val = try? container.decode(Double.self) {
                self = .double(val)
            } else if let val = try? container.decode(String.self) {
                self = .string(val)
            } else if let val = try? container.decode([JSONValue].self) {
                self = .array(val)
            } else if let val = try? container.decode([String: JSONValue].self) {
                self = .object(val)
            } else if container.decodeNil() {
                self = .null
            } else {
                throw DecodingError.typeMismatch(JSONValue.self, .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value"
                ))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let val): try container.encode(val)
            case .int(let val): try container.encode(val)
            case .double(let val): try container.encode(val)
            case .bool(let val): try container.encode(val)
            case .null: try container.encodeNil()
            case .array(let val): try container.encode(val)
            case .object(let val): try container.encode(val)
            }
        }
    }

    private static func parseToolCallJSON(_ jsonString: String) -> ParsedToolCall? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        guard let decoded = try? JSONDecoder().decode(ToolCallJSON.self, from: data) else {
            return nil
        }

        let name = decoded.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let arguments = decoded.arguments?.jsonString ?? "{}"
        return ParsedToolCall(name: name, arguments: arguments)
    }
}

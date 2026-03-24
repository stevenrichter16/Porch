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
    private static let logger = PorchLogger(category: "ToolParser")

    struct ParsedToolCall: Hashable {
        var name: String
        var arguments: String
    }

    struct ParseResult: Equatable {
        /// Tool calls extracted from the text.
        var toolCalls: [ParsedToolCall]
        /// The text with tool call blocks removed (the "spoken" content).
        var remainingText: String
    }

    static func parse(_ text: String) -> ParseResult {
        let xmlPattern = #/<tool_call>\s*\n?([\s\S]*?)\n?\s*</tool_call>/#
        let fencedPattern = #/```tool_call\s*\n([\s\S]*?)\n\s*```/#

        var toolCalls: [ParsedToolCall] = []
        var remaining = text

        for pattern in [xmlPattern, fencedPattern] {
            remaining = extractToolCalls(from: remaining, using: pattern, into: &toolCalls)
        }

        // Deduplicate in case both patterns matched overlapping content
        var seen = Set<ParsedToolCall>()
        toolCalls = toolCalls.filter { seen.insert($0).inserted }

        if toolCalls.isEmpty {
            let hasToolCallMarkers = text.contains("<tool_call>") || text.contains("```tool_call")
            logger.debug("[parse] noToolCallsFound inputLength=\(text.count) hasMarkers=\(hasToolCallMarkers) textSnippet=\(String(text.suffix(200)))")
        } else {
            for tc in toolCalls {
                logger.info("[parse] toolCall name=\(tc.name) argsLength=\(tc.arguments.count) args=\(tc.arguments.prefix(300))")
            }
            logger.info("[parse] foundToolCalls=\(toolCalls.count) names=\(toolCalls.map(\.name).joined(separator: ",")) remainingTextLength=\(remaining.count)")
        }

        return ParseResult(
            toolCalls: toolCalls,
            remainingText: remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Private

    private static func extractToolCalls<Output>(
        from text: String,
        using pattern: some RegexComponent<Output>,
        into toolCalls: inout [ParsedToolCall]
    ) -> String where Output == (Substring, Substring) {
        for match in text.matches(of: pattern) {
            let jsonString = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parseToolCallJSON(jsonString) {
                toolCalls.append(parsed)
            }
        }
        return text.replacing(pattern, with: "")
    }

    private static func parseToolCallJSON(_ jsonString: String) -> ParsedToolCall? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let arguments: String
        if let argsString = json["arguments"] as? String {
            arguments = argsString
        } else if let argsObj = json["arguments"],
                  let argsData = try? JSONSerialization.data(withJSONObject: argsObj) {
            arguments = String(data: argsData, encoding: .utf8) ?? "{}"
        } else {
            arguments = "{}"
        }

        return ParsedToolCall(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments
        )
    }
}

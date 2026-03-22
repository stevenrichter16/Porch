import Foundation

/// Controls how Porch sends tool definitions and parses tool call responses.
enum ToolCallingMode: String, CaseIterable, Sendable {
    /// Send the `tools` array in the API request AND inject a tool-calling
    /// instruction system prompt. Parse both structured `tool_calls` responses
    /// and text-based tool call blocks. Best compatibility across all models.
    case auto

    /// Send the `tools` array and rely on the model's native OpenAI-compatible
    /// tool calling support. Best for OpenAI, vLLM, and other runtimes that
    /// natively produce `tool_calls` deltas.
    case native

    /// Do NOT send the `tools` array. Instead, teach the model to call tools
    /// via a system prompt and parse tool calls from the model's text output.
    /// Best for local models that don't support structured tool calling.
    case promptBased

    var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .native:
            "Native"
        case .promptBased:
            "Prompt-Based"
        }
    }

    var subtitle: String {
        switch self {
        case .auto:
            "Send tools + parse text fallback"
        case .native:
            "OpenAI-compatible tool calling only"
        case .promptBased:
            "Teach via prompt, parse text output"
        }
    }
}

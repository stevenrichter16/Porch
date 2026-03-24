import Foundation

/// Builds system prompt instructions that teach an LLM how to call tools
/// by outputting structured text blocks, for models that don't natively
/// support OpenAI-style `tool_calls`.
enum ToolCallingPromptBuilder {

    /// Build the tool-calling instruction system prompt.
    ///
    /// - Parameters:
    ///   - tools: The tool definitions available in this chat.
    ///   - githubContext: Optional GitHub context for the chat.
    /// - Returns: A system prompt string teaching the model how to call tools.
    static func buildPrompt(
        tools: [ToolDefinition],
        githubContext: GitHubChatContext?
    ) -> String {
        var sections: [String] = []

        // Header
        sections.append("""
        You have access to tools. To call a tool, output a tool_call block like this:

        <tool_call>
        {"name": "tool_name", "arguments": {"param1": "value1"}}
        </tool_call>

        IMPORTANT RULES:
        - After outputting a tool_call, STOP and wait for the result. Do NOT guess or make up the result.
        - You may call multiple tools in one response by outputting multiple <tool_call> blocks.
        - The "arguments" value must be a JSON object matching the tool's parameters.
        - Only call tools that are listed below.
        """)

        // Tool listing
        var toolDescriptions: [String] = []
        for tool in tools {
            let params = describeParameters(tool.function.parameters)
            toolDescriptions.append("- \(tool.function.name)(\(params)): \(tool.function.description)")
        }
        sections.append("Available tools:\n" + toolDescriptions.joined(separator: "\n"))

        if let ctx = githubContext {
            sections.append(githubWorkflowInstructions(for: ctx))
        }

        // Worked example
        sections.append(buildWorkedExample(githubContext: githubContext))

        return sections.joined(separator: "\n\n")
    }

    /// GitHub workflow instructions shared between prompt-based and native tool calling modes.
    static func githubWorkflowInstructions(for ctx: GitHubChatContext) -> String {
        """
        You have access to the GitHub repository \(ctx.owner)/\(ctx.repo) (branch: \(ctx.branch)). \
        To edit an existing file, first read it with github_get_file_content, then call \
        github_commit_file_changes with operation "update" and the complete new file content. \
        To add a new file, use operation "create". To remove a file, use operation "delete" with no content. \
        You can mix create, update, and delete operations in a single commit.
        """
    }

    // MARK: - Private

    private static func describeParameters(_ schema: JSONSchemaValue) -> String {
        guard case .object(let topLevel) = schema,
              case .object(let props) = topLevel["properties"] else {
            return ""
        }

        let required: Set<String>
        if case .array(let arr) = topLevel["required"] {
            required = Set(arr.compactMap { val -> String? in
                if case .string(let s) = val { return s }
                return nil
            })
        } else {
            required = []
        }

        return props.keys.sorted().map { key in
            let isRequired = required.contains(key)
            return isRequired ? key : "\(key)?"
        }.joined(separator: ", ")
    }

    private static func buildWorkedExample(githubContext: GitHubChatContext?) -> String {
        if githubContext != nil {
            return """
            Example conversation:

            User: What's in the README?
            Assistant: I'll read the README file for you.

            <tool_call>
            {"name": "github_get_file_content", "arguments": {"path": "README.md"}}
            </tool_call>

            [After receiving the tool result, the assistant continues with the file content.]
            """
        } else {
            return """
            Example conversation:

            User: Search for information about Swift concurrency
            Assistant: I'll search the web for that.

            <tool_call>
            {"name": "web_search", "arguments": {"query": "Swift concurrency"}}
            </tool_call>

            [After receiving the tool result, the assistant continues with the search results.]
            """
        }
    }
}

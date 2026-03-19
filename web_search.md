# Web Search Connector Recommendations

## Highest Priority Fix

The most critical issue in the current implementation is a **schema typo** in the `web_search` function definition. The parameter `max_results` is mistakenly declared with a string type instead of an integer. This causes the connector to fail validation and can lead to runtime errors when users supply numeric values.

### Why This Matters
- **Immediate breakage** – The connector will not work in any production workflow.
- **Security & reliability** – Passing a string where an integer is expected can cause unpredictable behavior.
- **Developer confidence** – Correct schema types make the tool more robust and easier to maintain.

### Quick Patch Example (Swift)
```swift
private var searchWebTool: ToolDefinition {
    ToolDefinition(function: FunctionDefinitionBody(
        name: "web_search",
        description: "Search the web using DuckDuckGo. Returns titles, URLs, and snippets for matching pages.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([ // required
                    "type": .string("string"),
                    "description": .string("The search query.")
                ]),
                "max_results": .object([ // optional
                    "type": .string("integer"),
                    "description": .string("Maximum number of results to return (default 8, max 15)."),
                    "minimum": .int(1),
                    "maximum": .int(15)
                ])
            ]),
            "required": .array([.string("query")])
        ])
    ))
}
```

## Additional Recommendations
1. **Add `required` array** – Ensure required fields are explicitly listed.
2. **Validate defaults** – Provide default values or document them clearly.
3. **Unit tests** – Write tests that pass both valid and invalid inputs to verify schema enforcement.

By addressing the schema typo first, you restore functionality immediately while also laying a foundation for safer future enhancements.

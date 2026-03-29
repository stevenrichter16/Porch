import Foundation

/// Extracts `<think>...</think>` (and `<thinking>...</thinking>`) blocks from LLM output.
///
/// Used during streaming to separate reasoning content from visible response content,
/// so the UI can display thinking in a collapsible section.
enum ThinkingContentParser {

    struct Result: Equatable {
        /// The model's internal reasoning (content inside think tags).
        var thinking: String
        /// The visible response with think blocks removed.
        var visible: String
    }

    /// Parse completed text, extracting all think blocks.
    static func parse(_ text: String) -> Result {
        var thinking = ""
        var visible = text

        // Match <think>...</think> and <thinking>...</thinking>
        let patterns: [Regex<(Substring, Substring)>] = [
            #/<think>([\s\S]*?)<\/think>/#,
            #/<thinking>([\s\S]*?)<\/thinking>/#
        ]

        for pattern in patterns {
            let matches = visible.matches(of: pattern)
            for match in matches {
                let block = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    if !thinking.isEmpty { thinking += "\n\n" }
                    thinking += block
                }
            }
            visible = visible.replacing(pattern, with: "")
        }

        visible = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(thinking: thinking, visible: visible)
    }

    /// Determines if the text is currently inside an open think block (tag opened but not closed).
    /// Used during streaming to show "Thinking..." indicator.
    static func isInsideThinkBlock(_ text: String) -> Bool {
        // Count open and close tags
        let openCount = countOccurrences(of: "<think>", in: text)
            + countOccurrences(of: "<thinking>", in: text)
        let closeCount = countOccurrences(of: "</think>", in: text)
            + countOccurrences(of: "</thinking>", in: text)

        return openCount > closeCount
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}

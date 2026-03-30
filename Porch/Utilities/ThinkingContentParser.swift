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
    /// Uses iterative tag matching to correctly handle nested tags.
    static func parse(_ text: String) -> Result {
        var thinking = ""
        var visible = text

        for tagName in ["think", "thinking"] {
            let openTag = "<\(tagName)>"
            let closeTag = "</\(tagName)>"

            while let openRange = visible.range(of: openTag),
                  let closeRange = visible.range(of: closeTag, range: openRange.upperBound..<visible.endIndex) {
                let block = String(visible[openRange.upperBound..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    if !thinking.isEmpty { thinking += "\n\n" }
                    thinking += block
                }
                visible.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            }
        }

        visible = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(thinking: thinking, visible: visible)
    }

    /// Determines if the text is currently inside an open think block (tag opened but not closed).
    /// Used during streaming to show "Thinking..." indicator.
    static func isInsideThinkBlock(_ text: String) -> Bool {
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

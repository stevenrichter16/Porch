import Foundation

/// Generates a concise title for a chat from its first message.
///
/// The implementation normalises whitespace, trims surrounding
/// spaces, and limits the result to 48 characters. When longer,
/// it truncates at 45 characters and appends an ellipsis.
public enum ChatTitleGenerator {
    public static func title(for message: String) -> String {
        // Collapse any consecutive whitespace (including newlines) into a single space.
        let collapsed = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New Chat" }

        // If the title fits within 48 characters, use it verbatim.
        if trimmed.count <= 48 { return trimmed }

        // Truncate to 45 characters and append "...".
        let prefix = trimmed.prefix(45)
        return "\(prefix)..."
    }
}

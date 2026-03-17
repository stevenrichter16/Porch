import Foundation

enum ChatTitleGenerator {
    static func title(for message: String) -> String {
        let collapsed = message
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return "New Chat" }
        if collapsed.count <= 48 {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 45)
        return "\(collapsed[..<endIndex])..."
    }
}

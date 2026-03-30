import Foundation

enum SSELineParseResult {
    case chunk(ChatCompletionChunk)
    case done
    case ignore
}

struct SSEParser {
    private static let logger = PorchLogger(category: "SSEParser")
    private let decoder = JSONDecoder()

    func parse(line: String) throws -> SSELineParseResult {
        if line.isEmpty || line.hasPrefix(":") {
            return .ignore
        }

        guard line.hasPrefix("data:") else {
            return .ignore
        }

        let payload = line
            .dropFirst(5)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if payload == "[DONE]" {
            return .done
        }

        guard let data = payload.data(using: .utf8) else {
            return .ignore
        }

        do {
            return .chunk(try decoder.decode(ChatCompletionChunk.self, from: data))
        } catch {
            Self.logger.debug("[chunk] malformed error=\(error.localizedDescription) payload=\(payload.prefix(200))")
            return .ignore
        }
    }
}

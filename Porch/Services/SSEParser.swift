import Foundation

enum SSELineParseResult {
    case chunk(ChatCompletionChunk)
    case done
    case ignore
}

struct SSEParser {
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
            // Tolerate malformed chunks (e.g., from local LLM servers with non-standard
            // streaming formats) instead of aborting the entire stream.
            return .ignore
        }
    }
}

import Foundation
import os

enum SSELineParseResult {
    case chunk(ChatCompletionChunk)
    case done
    case ignore
}

struct SSEParser {
    private static let logger = Logger(subsystem: "com.porch.app", category: "SSEParser")
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
            Self.logger.debug("Skipping malformed SSE chunk: \(error.localizedDescription, privacy: .public)")
            return .ignore
        }
    }
}

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
            throw StreamError.malformedStream("Unable to decode streamed payload.")
        }

        do {
            return .chunk(try decoder.decode(ChatCompletionChunk.self, from: data))
        } catch {
            throw StreamError.malformedStream("Invalid SSE JSON chunk: \(error.localizedDescription)")
        }
    }
}

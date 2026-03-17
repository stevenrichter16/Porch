import Foundation

struct OpenAIChatMessage: Codable, Equatable {
    var role: String
    var content: String
}

struct OpenAIChatRequestDescriptor: Equatable {
    var configuration: ServerConfiguration
    var modelID: String
    var messages: [OpenAIChatMessage]
    var parameters: GenerationParameters
}

struct ChatCompletionRequestBody: Encodable {
    var model: String
    var messages: [OpenAIChatMessage]
    var stream: Bool
    var temperature: Double
    var max_tokens: Int
    var top_p: Double
    var frequency_penalty: Double
    var presence_penalty: Double
    var stop: [String]?
}

struct ModelsResponseBody: Decodable {
    struct ModelObject: Decodable {
        var id: String
        var owned_by: String?
    }

    var data: [ModelObject]
}

struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var role: String?
            var content: String?
        }

        var index: Int
        var delta: Delta
        var finish_reason: String?
    }

    var choices: [Choice]
}

struct ChatCompletionResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var role: String
            var content: String
        }

        var index: Int
        var message: Message
        var finish_reason: String?
    }

    var choices: [Choice]
}

struct NonStreamingCompletionResult {
    var content: String
    var finishReason: ChatFinishReason?
}

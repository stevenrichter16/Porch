import Foundation

struct GenerationParameters: Codable, Equatable {
    var temperature: Double
    var maxTokens: Int
    var topP: Double
    var frequencyPenalty: Double
    var presencePenalty: Double
    var stopSequences: [String]

    static let `default` = GenerationParameters(
        temperature: 0.7,
        maxTokens: 2048,
        topP: 1.0,
        frequencyPenalty: 0.0,
        presencePenalty: 0.0,
        stopSequences: []
    )
}

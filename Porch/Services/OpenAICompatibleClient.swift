import Foundation

enum StreamError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case malformedStream(String)
    case emptyResponse
    case missingModels

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid server URL."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpError(let statusCode, let body):
            if body.isEmpty {
                return "Server error \(statusCode)."
            }
            return "Server error \(statusCode): \(body)"
        case .malformedStream(let message):
            return message
        case .emptyResponse:
            return "The server returned an empty response."
        case .missingModels:
            return "No models were returned by /v1/models."
        }
    }
}

actor OpenAICompatibleClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let sseParser: SSEParser

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        sseParser: SSEParser = SSEParser()
    ) {
        self.session = session
        self.decoder = decoder
        self.sseParser = sseParser
    }

    func fetchModels(configuration: ServerConfiguration) async throws -> [RemoteModel] {
        let request = try buildModelsRequest(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, body: data)
        let decoded = try decoder.decode(ModelsResponseBody.self, from: data)
        let models = decoded.data.map { RemoteModel(id: $0.id, ownedBy: $0.owned_by) }
        guard !models.isEmpty else {
            throw StreamError.missingModels
        }
        return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    func streamCompletion(request descriptor: OpenAIChatRequestDescriptor) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStreamingRequest(
                        descriptor: descriptor,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func performStreamingRequest(
        descriptor: OpenAIChatRequestDescriptor,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var yieldedContent = false

        do {
            let request = try buildChatCompletionRequest(descriptor: descriptor, stream: true)
            let (bytes, response) = try await session.bytes(for: request)
            try await validateStreamingHTTP(response: response, lines: bytes.lines)

            var finishReason: ChatFinishReason?
            for try await line in bytes.lines {
                try Task.checkCancellation()

                switch try sseParser.parse(line: line) {
                case .ignore:
                    continue
                case .done:
                    continuation.yield(.completed(finishReason))
                    continuation.finish()
                    return
                case .chunk(let chunk):
                    if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                        yieldedContent = true
                        continuation.yield(.token(content))
                    }

                    if let rawReason = chunk.choices.first?.finish_reason {
                        finishReason = ChatFinishReason(apiValue: rawReason)
                    }
                }
            }

            continuation.yield(.completed(finishReason))
            continuation.finish()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if yieldedContent {
                throw error
            }

            let fallback = try await fetchNonStreamingCompletion(descriptor: descriptor)
            continuation.yield(.token(fallback.content))
            continuation.yield(.completed(fallback.finishReason))
            continuation.finish()
        }
    }

    private func fetchNonStreamingCompletion(descriptor: OpenAIChatRequestDescriptor) async throws -> NonStreamingCompletionResult {
        let request = try buildChatCompletionRequest(descriptor: descriptor, stream: false)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, body: data)
        let decoded = try decoder.decode(ChatCompletionResponseBody.self, from: data)

        guard let firstChoice = decoded.choices.first else {
            throw StreamError.emptyResponse
        }

        let content = firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw StreamError.emptyResponse
        }

        let finishReason = firstChoice.finish_reason.map(ChatFinishReason.init(apiValue:))
        return NonStreamingCompletionResult(content: content, finishReason: finishReason)
    }

    func normalizeBaseURL(_ input: String) throws -> URL {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StreamError.invalidBaseURL
        }

        if !trimmed.contains("://") {
            trimmed = "http://\(trimmed)"
        }

        guard
            var components = URLComponents(string: trimmed),
            let host = components.host,
            !host.isEmpty
        else {
            throw StreamError.invalidBaseURL
        }

        let existingPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if existingPath.isEmpty {
            components.percentEncodedPath = "/v1"
        } else if existingPath.lowercased().hasSuffix("/v1") || existingPath.lowercased() == "v1" {
            components.percentEncodedPath = "/\(existingPath)"
        } else {
            components.percentEncodedPath = "/\(existingPath)/v1"
        }

        guard let url = components.url else {
            throw StreamError.invalidBaseURL
        }

        return url
    }

    private func buildModelsRequest(configuration: ServerConfiguration) throws -> URLRequest {
        let baseURL = try normalizeBaseURL(configuration.baseURL)
        let url = baseURL.appending(path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        applyHeaders(to: &request, configuration: configuration)
        return request
    }

    private func buildChatCompletionRequest(
        descriptor: OpenAIChatRequestDescriptor,
        stream: Bool
    ) throws -> URLRequest {
        let baseURL = try normalizeBaseURL(descriptor.configuration.baseURL)
        let url = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        applyHeaders(to: &request, configuration: descriptor.configuration)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequestBody(
            model: descriptor.modelID,
            messages: descriptor.messages,
            stream: stream,
            temperature: descriptor.parameters.temperature,
            max_tokens: descriptor.parameters.maxTokens,
            top_p: descriptor.parameters.topP,
            frequency_penalty: descriptor.parameters.frequencyPenalty,
            presence_penalty: descriptor.parameters.presencePenalty,
            stop: descriptor.parameters.stopSequences.isEmpty ? nil : descriptor.parameters.stopSequences
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func applyHeaders(to request: inout URLRequest, configuration: ServerConfiguration) {
        if let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validateHTTP(response: URLResponse, body: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: body, encoding: .utf8) ?? ""
            throw StreamError.httpError(statusCode: httpResponse.statusCode, body: message)
        }
    }

    private func validateStreamingHTTP<Lines: AsyncSequence>(
        response: URLResponse,
        lines: Lines
    ) async throws where Lines.Element == String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamError.invalidResponse
        }

        guard !(200 ... 299).contains(httpResponse.statusCode) else {
            return
        }

        var body = ""
        for try await line in lines {
            body.append(line)
        }
        throw StreamError.httpError(statusCode: httpResponse.statusCode, body: body)
    }
}

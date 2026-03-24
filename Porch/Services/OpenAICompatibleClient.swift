import Foundation
import os

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
    private static let logger = Logger(subsystem: "com.porch.app", category: "API")
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
        Self.logger.info("[fetchModels] baseURL=\(configuration.baseURL, privacy: .public)")
        let request = try buildModelsRequest(configuration: configuration)
        do {
            let (data, response) = try await session.data(for: request)
            try validateHTTP(response: response, body: data)
            let decoded = try decoder.decode(ModelsResponseBody.self, from: data)
            let models = decoded.data.map { RemoteModel(id: $0.id, ownedBy: $0.owned_by) }
            guard !models.isEmpty else {
                throw StreamError.missingModels
            }
            Self.logger.info("[fetchModels] modelCount=\(models.count)")
            return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        } catch {
            Self.logger.error("[fetchModels] error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
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
        Self.logger.info("[stream] model=\(descriptor.modelID, privacy: .public) messageCount=\(descriptor.messages.count) hasTools=\(descriptor.tools != nil) toolCount=\(descriptor.tools?.count ?? 0)")
        var yieldedContent = false

        do {
            let request = try buildChatCompletionRequest(descriptor: descriptor, stream: true)
            let (bytes, response) = try await session.bytes(for: request)
            try await validateStreamingHTTP(response: response, lines: bytes.lines)

            var finishReason: ChatFinishReason?
            // Accumulate streaming tool call deltas by index
            var toolCallAccumulator: [Int: (id: String, name: String, arguments: String)] = [:]

            for try await line in bytes.lines {
                try Task.checkCancellation()

                switch try sseParser.parse(line: line) {
                case .ignore:
                    continue
                case .done:
                    // If we accumulated tool calls, yield them before completing
                    if !toolCallAccumulator.isEmpty {
                        let assembled = assembleToolCalls(from: toolCallAccumulator)
                        Self.logger.info("[stream] assembledToolCalls=\(assembled.count) tools=\(assembled.map(\.function.name).joined(separator: ","), privacy: .public)")
                        continuation.yield(.toolCalls(assembled))
                    }
                    Self.logger.info("[stream] completed finishReason=\(finishReason?.apiValue ?? "nil", privacy: .public)")
                    continuation.yield(.completed(finishReason))
                    continuation.finish()
                    return
                case .chunk(let chunk):
                    if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                        yieldedContent = true
                        continuation.yield(.token(content))
                    }

                    // Accumulate tool call deltas
                    if let toolCallDeltas = chunk.choices.first?.delta.tool_calls {
                        for delta in toolCallDeltas {
                            let idx = delta.index ?? 0
                            if let existingEntry = toolCallAccumulator[idx] {
                                // Append arguments fragment
                                let appendedArgs = existingEntry.arguments + (delta.function?.arguments ?? "")
                                toolCallAccumulator[idx] = (
                                    id: existingEntry.id,
                                    name: existingEntry.name,
                                    arguments: appendedArgs
                                )
                            } else {
                                // First delta for this index
                                toolCallAccumulator[idx] = (
                                    id: delta.id ?? "",
                                    name: delta.function?.name ?? "",
                                    arguments: delta.function?.arguments ?? ""
                                )
                            }
                        }
                    }

                    if let rawReason = chunk.choices.first?.finish_reason {
                        finishReason = ChatFinishReason(apiValue: rawReason)
                    }
                }
            }

            // Stream ended without [DONE]
            Self.logger.info("[stream] endedWithoutDONE finishReason=\(finishReason?.apiValue ?? "nil", privacy: .public)")
            if !toolCallAccumulator.isEmpty {
                let assembled = assembleToolCalls(from: toolCallAccumulator)
                Self.logger.info("[stream] assembledToolCalls=\(assembled.count) tools=\(assembled.map(\.function.name).joined(separator: ","), privacy: .public)")
                continuation.yield(.toolCalls(assembled))
            }
            continuation.yield(.completed(finishReason))
            continuation.finish()
        } catch is CancellationError {
            Self.logger.debug("[stream] cancelled")
            throw CancellationError()
        } catch {
            if yieldedContent {
                throw error
            }

            Self.logger.info("[stream] streamingFailed fallingBackToNonStreaming error=\(error.localizedDescription, privacy: .public)")
            let fallback = try await fetchNonStreamingCompletion(descriptor: descriptor)
            if let toolCalls = fallback.toolCalls, !toolCalls.isEmpty {
                continuation.yield(.toolCalls(toolCalls))
            } else if let content = fallback.content {
                continuation.yield(.token(content))
            }
            continuation.yield(.completed(fallback.finishReason))
            continuation.finish()
        }
    }

    private func assembleToolCalls(from accumulator: [Int: (id: String, name: String, arguments: String)]) -> [ToolCall] {
        accumulator
            .sorted { $0.key < $1.key }
            .compactMap { _, entry in
                // Filter out entries with empty names — these are malformed and will fail execution
                guard !entry.name.isEmpty else { return nil }
                let id = entry.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : entry.id
                return ToolCall(id: id, function: FunctionCall(name: entry.name, arguments: entry.arguments))
            }
    }

    private func fetchNonStreamingCompletion(descriptor: OpenAIChatRequestDescriptor) async throws -> NonStreamingCompletionResult {
        Self.logger.info("[nonStream] model=\(descriptor.modelID, privacy: .public) messageCount=\(descriptor.messages.count)")
        let request = try buildChatCompletionRequest(descriptor: descriptor, stream: false)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, body: data)
        let decoded = try decoder.decode(ChatCompletionResponseBody.self, from: data)

        guard let firstChoice = decoded.choices.first else {
            Self.logger.error("[nonStream] emptyResponse noChoices")
            throw StreamError.emptyResponse
        }

        let finishReason = firstChoice.finish_reason.map(ChatFinishReason.init(apiValue:))

        // Check for tool calls
        if let toolCalls = firstChoice.message.tool_calls, !toolCalls.isEmpty {
            Self.logger.info("[nonStream] result hasToolCalls=\(toolCalls.count) tools=\(toolCalls.map(\.function.name).joined(separator: ","), privacy: .public) finishReason=\(finishReason?.apiValue ?? "nil", privacy: .public)")
            return NonStreamingCompletionResult(
                content: firstChoice.message.content,
                toolCalls: toolCalls,
                finishReason: finishReason
            )
        }

        let content = (firstChoice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            Self.logger.error("[nonStream] emptyResponse emptyContent")
            throw StreamError.emptyResponse
        }

        Self.logger.info("[nonStream] result contentLength=\(content.count) finishReason=\(finishReason?.apiValue ?? "nil", privacy: .public)")
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
            stop: descriptor.parameters.stopSequences.isEmpty ? nil : descriptor.parameters.stopSequences,
            tools: descriptor.tools?.isEmpty == true ? nil : descriptor.tools
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
            Self.logger.error("[http] statusCode=\(httpResponse.statusCode) body=\(message.prefix(1000), privacy: .public)")
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
        Self.logger.error("[http] streaming statusCode=\(httpResponse.statusCode) body=\(body.prefix(1000), privacy: .public)")
        throw StreamError.httpError(statusCode: httpResponse.statusCode, body: body)
    }
}

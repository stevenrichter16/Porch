import XCTest
@testable import Porch

final class OpenAICompatibleClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testFetchModelsReturnsSortedModelsAndUsesNormalizedV1Path() async throws {
        MockURLProtocol.setRequestHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://macbook.local:1234/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return .data(
                body: try self.makeModelsResponse([
                    ["id": "zeta", "owned_by": "owner-b"],
                    ["id": "alpha", "owned_by": "owner-a"]
                ])
            )
        }

        let client = makeClient()
        let models = try await client.fetchModels(
            configuration: ServerConfiguration(baseURL: "macbook.local:1234", apiKey: "secret")
        )

        XCTAssertEqual(models.map(\.id), ["alpha", "zeta"])
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    func testFetchModelsThrowsWhenServerReturnsNoModels() async {
        MockURLProtocol.setRequestHandler { _ in
            .data(body: try self.makeModelsResponse([]))
        }

        let client = makeClient()

        do {
            _ = try await client.fetchModels(configuration: ServerConfiguration(baseURL: "http://server.test", apiKey: nil))
            XCTFail("Expected missingModels error.")
        } catch let error as StreamError {
            XCTAssertEqual(error, .missingModels)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchModelsPropagatesHTTPErrorBody() async {
        MockURLProtocol.setRequestHandler { _ in
            .data(statusCode: 401, body: Data("bad token".utf8))
        }

        let client = makeClient()

        do {
            _ = try await client.fetchModels(configuration: ServerConfiguration(baseURL: "http://server.test", apiKey: nil))
            XCTFail("Expected httpError.")
        } catch let error as StreamError {
            XCTAssertEqual(error, .httpError(statusCode: 401, body: "bad token"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamCompletionSendsExpectedRequestBodyAndHeaders() async throws {
        let requestDescriptor = makeDescriptor()

        MockURLProtocol.setRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "http://server.test:8080/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try self.decodeJSONBody(from: request)
            XCTAssertEqual(body["model"] as? String, "llama-3")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["temperature"] as? Double, 0.3)
            XCTAssertEqual(body["max_tokens"] as? Int, 512)
            XCTAssertEqual(body["top_p"] as? Double, 0.9)
            XCTAssertEqual(body["frequency_penalty"] as? Double, 0.1)
            XCTAssertEqual(body["presence_penalty"] as? Double, -0.1)
            XCTAssertEqual(body["stop"] as? [String], ["END"])

            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [
                ["role": "system", "content": "You are concise."],
                ["role": "user", "content": "Hi there"]
            ])

            return .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Hello", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        let events = try await collectEvents(from: await makeClient().streamCompletion(request: requestDescriptor))

        XCTAssertEqual(events, [
            .token("Hello"),
            .completed(.stop)
        ])
    }

    func testStreamCompletionIgnoresCommentsBlankLinesAndNilDeltaContent() async throws {
        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                Data("\n".utf8),
                Data(": keepalive\n".utf8),
                try self.makeSSEChunk(content: nil, finishReason: nil),
                try self.makeSSEChunk(content: "Hello", finishReason: nil),
                try self.makeSSEChunkWithoutSpace(content: " world"),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        let events = try await collectEvents(from: await makeClient().streamCompletion(request: makeDescriptor()))

        XCTAssertEqual(events, [
            .token("Hello"),
            .token(" world"),
            .completed(.stop)
        ])
    }

    func testStreamCompletionFallsBackToNonStreamingBeforeFirstToken() async throws {
        MockURLProtocol.setRequestHandler { request in
            let body = try self.decodeJSONBody(from: request)
            let isStreaming = body["stream"] as? Bool ?? false

            if isStreaming {
                return .stream(bodyChunks: [
                    Data("data: {bad json}\n".utf8)
                ])
            }

            return .data(body: try self.makeNonStreamingResponse(content: "Fallback reply", finishReason: "stop"))
        }

        let events = try await collectEvents(from: await makeClient().streamCompletion(request: makeDescriptor()))

        XCTAssertEqual(events, [
            .token("Fallback reply"),
            .completed(.stop)
        ])
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(try streamFlag(from: MockURLProtocol.capturedRequests[0]), true)
        XCTAssertEqual(try streamFlag(from: MockURLProtocol.capturedRequests[1]), false)
    }

    func testStreamCompletionDoesNotFallbackAfterFirstToken() async {
        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Partial", finishReason: nil),
                Data("data: {bad json}\n".utf8)
            ])
        }

        var receivedEvents: [ChatStreamEvent] = []

        do {
            let stream = await makeClient().streamCompletion(request: makeDescriptor())
            for try await event in stream {
                receivedEvents.append(event)
            }
            XCTFail("Expected malformedStream error.")
        } catch let error as StreamError {
            switch error {
            case .malformedStream:
                XCTAssertEqual(receivedEvents, [.token("Partial")])
                XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
            default:
                XCTFail("Unexpected stream error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamCompletionThrowsEmptyResponseWhenFallbackBodyIsBlank() async {
        MockURLProtocol.setRequestHandler { request in
            let isStreaming = try self.streamFlag(from: request)
            if isStreaming {
                return .stream(bodyChunks: [Data("data: {bad json}\n".utf8)])
            }

            return .data(body: try self.makeNonStreamingResponse(content: "   ", finishReason: "stop"))
        }

        do {
            let stream = await makeClient().streamCompletion(request: makeDescriptor())
            for try await _ in stream {
            }
            XCTFail("Expected emptyResponse error.")
        } catch let error as StreamError {
            XCTAssertEqual(error, .emptyResponse)
            XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> OpenAICompatibleClient {
        OpenAICompatibleClient(session: TestSessionFactory.makeSession())
    }

    private func makeDescriptor() -> OpenAIChatRequestDescriptor {
        OpenAIChatRequestDescriptor(
            configuration: ServerConfiguration(baseURL: "http://server.test:8080", apiKey: "secret"),
            modelID: "llama-3",
            messages: [
                OpenAIChatMessage(role: "system", content: "You are concise."),
                OpenAIChatMessage(role: "user", content: "Hi there")
            ],
            parameters: GenerationParameters(
                temperature: 0.3,
                maxTokens: 512,
                topP: 0.9,
                frequencyPenalty: 0.1,
                presencePenalty: -0.1,
                stopSequences: ["END"]
            )
        )
    }

    private func collectEvents(from stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func decodeJSONBody(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func streamFlag(from request: URLRequest) throws -> Bool {
        let body = try decodeJSONBody(from: request)
        return try XCTUnwrap(body["stream"] as? Bool)
    }

    private func makeModelsResponse(_ models: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": models])
    }

    private func makeNonStreamingResponse(content: String, finishReason: String?) throws -> Data {
        let finishReasonValue: Any = finishReason.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(
            withJSONObject: [
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": content
                        ],
                        "finish_reason": finishReasonValue
                    ]
                ]
            ]
        )
    }

    private func makeSSEChunk(content: String?, finishReason: String?) throws -> Data {
        var delta: [String: Any] = [:]
        if let content {
            delta["content"] = content
        }
        let finishReasonValue: Any = finishReason.map { $0 as Any } ?? NSNull()

        let payload = try JSONSerialization.data(
            withJSONObject: [
                "choices": [
                    [
                        "index": 0,
                        "delta": delta,
                        "finish_reason": finishReasonValue
                    ]
                ]
            ]
        )

        var line = Data("data: ".utf8)
        line.append(payload)
        line.append(Data("\n".utf8))
        return line
    }

    private func makeSSEChunkWithoutSpace(content: String) throws -> Data {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "choices": [
                    [
                        "index": 0,
                        "delta": [
                            "content": content
                        ],
                        "finish_reason": NSNull()
                    ]
                ]
            ]
        )

        var line = Data("data:".utf8)
        line.append(payload)
        line.append(Data("\n".utf8))
        return line
    }
}

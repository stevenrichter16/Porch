# SSE Streaming with URLSession — Implementation Guide

## How It Works

The OpenAI-compatible `/v1/chat/completions` endpoint, when called with `"stream": true`, returns a response using the Server-Sent Events (SSE) protocol. Instead of waiting for the entire response, the server sends incremental chunks as they're generated, each prefixed with `data: `. The stream terminates with a special `data: [DONE]` sentinel.

The raw HTTP response looks like this:

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Transfer-Encoding: chunked

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

Each `data:` line contains a JSON object with a `choices` array. Each choice has a `delta` object (not `message` like in non-streaming responses). The `delta` contains only the *new* content for that chunk — usually just a few characters or a single token. The client accumulates these deltas to build the full response.

---

## The Key API: `URLSession.bytes(for:)`

Available since iOS 15, `URLSession.bytes(for:)` returns a tuple of `(URLSession.AsyncBytes, URLResponse)`. The `AsyncBytes` type conforms to `AsyncSequence`, meaning you can iterate over incoming bytes as they arrive without blocking.

Critically, `AsyncBytes` has a `.lines` property that yields an `AsyncSequence` of `String` — it buffers bytes until a newline is received and hands you complete lines. This is exactly what SSE parsing needs, since each SSE event is newline-delimited.

```swift
let (bytes, response) = try await URLSession.shared.bytes(for: request)

for try await line in bytes.lines {
    // Each `line` is a complete line from the stream
    // e.g., "data: {\"id\":\"chatcmpl-abc\", ...}"
}
```

This is the foundation of the entire implementation. No third-party SSE libraries are needed.

---

## Codable Models for the SSE Chunks

The streaming response uses a slightly different schema from the non-streaming response. The key difference is `delta` instead of `message`.

```swift
/// The request body sent to POST /v1/chat/completions
struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double?
    let max_tokens: Int?
    let top_p: Double?
    let frequency_penalty: Double?
    let presence_penalty: Double?
    let stop: [String]?
}

struct ChatMessage: Codable {
    let role: String      // "system", "user", "assistant"
    let content: String
}

/// A single streaming chunk from the SSE response
struct ChatCompletionChunk: Decodable {
    let id: String
    let object: String        // "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [ChunkChoice]
    let usage: Usage?         // Only present on the final chunk if
                              // `stream_options.include_usage` is set

    struct ChunkChoice: Decodable {
        let index: Int
        let delta: Delta
        let finish_reason: String?   // nil until final chunk, then "stop", "length", etc.

        struct Delta: Decodable {
            let role: String?        // Present on first chunk only
            let content: String?     // The actual token text — this is what you append
        }
    }

    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

/// Model info returned by GET /v1/models
struct ModelList: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
        let object: String
        let owned_by: String?
    }
}
```

---

## Building the URLRequest

```swift
func buildStreamingRequest(
    baseURL: String,
    model: String,
    messages: [ChatMessage],
    temperature: Double = 0.7,
    maxTokens: Int? = nil,
    apiKey: String? = nil
) throws -> URLRequest {
    guard let url = URL(string: "\(baseURL)/chat/completions") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Optional Bearer token — some local servers require it, some don't
    if let apiKey = apiKey, !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    // Generous timeout: local models can take a long time on first token
    // especially during prompt processing on large contexts
    request.timeoutInterval = 120

    let body = ChatCompletionRequest(
        model: model,
        messages: messages,
        stream: true,
        temperature: temperature,
        max_tokens: maxTokens,
        top_p: nil,
        frequency_penalty: nil,
        presence_penalty: nil,
        stop: nil
    )
    request.httpBody = try JSONEncoder().encode(body)

    return request
}
```

---

## The SSE Line Parser

Each line from `bytes.lines` needs to be checked:

1. Lines starting with `data: ` contain payload
2. The payload `[DONE]` signals end of stream
3. Empty lines are SSE event separators (skip them)
4. Lines starting with `:` are SSE comments (skip them)

```swift
/// Parses a single SSE line and returns the extracted content token, or nil
func parseSSELine(_ line: String) -> SSEEvent {
    // Empty lines are event separators
    guard !line.isEmpty else {
        return .empty
    }

    // SSE comments start with ":"
    guard !line.hasPrefix(":") else {
        return .comment
    }

    // Data lines
    guard line.hasPrefix("data: ") else {
        // Some servers emit "data:" without a space — handle both
        if line.hasPrefix("data:") {
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return parsePayload(payload)
        }
        return .unknown(line)
    }

    let payload = String(line.dropFirst(6)) // Remove "data: " prefix
    return parsePayload(payload)
}

private func parsePayload(_ payload: String) -> SSEEvent {
    // Terminal sentinel
    if payload == "[DONE]" {
        return .done
    }

    // Parse the JSON chunk
    guard let data = payload.data(using: .utf8) else {
        return .error("Failed to encode payload as UTF-8")
    }

    do {
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        return .chunk(chunk)
    } catch {
        return .error("JSON decode failed: \(error.localizedDescription)")
    }
}

enum SSEEvent {
    case chunk(ChatCompletionChunk)
    case done
    case empty
    case comment
    case unknown(String)
    case error(String)
}
```

---

## The Streaming Client

This is the core service that ties the URLRequest, the byte stream, and the SSE parser together. It exposes an `AsyncThrowingStream` that the ViewModel can consume.

```swift
actor StreamingChatClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Streams chat completion tokens as an AsyncThrowingStream of strings.
    /// Each yielded string is a content delta (typically a word or partial word).
    func streamCompletion(request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    // Validate HTTP response
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: StreamError.invalidResponse)
                        return
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        // Try to read error body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.finish(
                            throwing: StreamError.httpError(
                                statusCode: httpResponse.statusCode,
                                body: errorBody
                            )
                        )
                        return
                    }

                    // Process the SSE stream line by line
                    for try await line in bytes.lines {
                        // Check for task cancellation (stop button)
                        try Task.checkCancellation()

                        switch parseSSELine(line) {
                        case .chunk(let chunk):
                            if let content = chunk.choices.first?.delta.content {
                                continuation.yield(content)
                            }
                            // Check if the model signaled stop
                            if chunk.choices.first?.finish_reason != nil {
                                // Model finished — [DONE] should follow
                            }
                        case .done:
                            break // Stream complete
                        case .empty, .comment:
                            continue
                        case .unknown(let line):
                            print("Unknown SSE line: \(line)")
                        case .error(let message):
                            print("SSE parse error: \(message)")
                        }
                    }

                    continuation.finish()

                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Wire up cancellation: when the consumer cancels the stream,
            // cancel the underlying URLSession task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

enum StreamError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        }
    }
}
```

### Why `AsyncThrowingStream`?

The `URLSession.bytes(for:)` method gives us an `AsyncSequence` that's tied to the URLSession's lifecycle. Wrapping it in an `AsyncThrowingStream` gives us:

- **Cancellation control**: The `onTermination` handler lets us cancel the underlying network task when the consumer (ViewModel) stops listening — this is the "Stop Generating" button.
- **Clean API boundary**: The ViewModel doesn't need to know about URLSession, HTTP, or SSE. It just iterates over strings.
- **Error propagation**: Network errors, HTTP errors, and JSON decode errors all flow through cleanly.

---

## The ViewModel (SwiftUI Integration)

The ViewModel is annotated `@MainActor` so all `@Published` property updates happen on the main thread automatically. The streaming loop runs within a `Task` — since URLSession's `bytes(for:)` is an async I/O operation, it suspends at each `await` and does *not* block the main thread.

```swift
import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var streamingText: String = ""
    @Published var isStreaming: Bool = false
    @Published var error: String?

    private let client = StreamingChatClient()
    private var streamTask: Task<Void, Never>?

    // Server configuration
    var baseURL: String = "http://192.168.1.100:1234/v1"
    var selectedModel: String = ""
    var apiKey: String? = nil
    var systemPrompt: String = "You are a helpful assistant."

    func send(_ userMessage: String) {
        // Append user message
        messages.append(ChatMessage(role: "user", content: userMessage))

        // Reset state
        streamingText = ""
        isStreaming = true
        error = nil

        // Build the full message history to send
        var apiMessages: [ChatMessage] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(ChatMessage(role: "system", content: systemPrompt))
        }
        apiMessages.append(contentsOf: messages)

        streamTask = Task {
            do {
                let request = try buildStreamingRequest(
                    baseURL: baseURL,
                    model: selectedModel,
                    messages: apiMessages,
                    apiKey: apiKey
                )

                let stream = client.streamCompletion(request: request)

                for try await token in stream {
                    streamingText += token
                }

                // Streaming complete — commit the assistant message
                messages.append(ChatMessage(role: "assistant", content: streamingText))
                streamingText = ""

            } catch is CancellationError {
                // User tapped stop — commit whatever we have so far
                if !streamingText.isEmpty {
                    messages.append(ChatMessage(role: "assistant", content: streamingText))
                    streamingText = ""
                }
            } catch {
                self.error = error.localizedDescription
            }

            isStreaming = false
        }
    }

    func stopGenerating() {
        streamTask?.cancel()
    }
}
```

### Threading Model Explained

This is worth understanding clearly:

1. `ChatViewModel` is `@MainActor`, so `send()` runs on the main thread.
2. Inside `send()`, we create a `Task`. Because the enclosing context is `@MainActor`, this Task also inherits the main actor.
3. The `for try await token in stream` line is a suspension point. When the stream is waiting for the next SSE line from the network, the main thread is **free to handle UI events** (scrolling, tapping stop, etc.).
4. When a token arrives, execution resumes on the main actor, and `streamingText += token` triggers a SwiftUI view update.
5. This means you get main-thread UI updates *without* any `DispatchQueue.main.async` or `MainActor.run {}` calls — it's handled automatically by Swift Concurrency.

---

## SwiftUI View (Minimal Chat UI)

```swift
struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(viewModel.messages.enumerated()), id: \.offset) { index, message in
                            MessageBubble(message: message)
                                .id(index)
                        }

                        // Show streaming text as it arrives
                        if viewModel.isStreaming && !viewModel.streamingText.isEmpty {
                            MessageBubble(
                                message: ChatMessage(role: "assistant", content: viewModel.streamingText)
                            )
                            .id("streaming")
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.streamingText) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }

            // Error display
            if let error = viewModel.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            Divider()

            // Input bar
            HStack {
                TextField("Message", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                if viewModel.isStreaming {
                    Button("Stop") {
                        viewModel.stopGenerating()
                    }
                    .foregroundStyle(.red)
                } else {
                    Button("Send") {
                        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        inputText = ""
                        viewModel.send(text)
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
    }
}
```

---

## App Transport Security (ATS)

This is a critical iOS-specific concern. By default, iOS blocks all cleartext HTTP connections. Since local LLM servers typically run on `http://192.168.x.x:1234` (no TLS), you must configure ATS exceptions.

### The `NSAllowsLocalNetworking` Key

Apple provides a purpose-built key for exactly this scenario. Add to your `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

This allows cleartext HTTP connections to **local network addresses only** (IP addresses in private ranges like `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, and `localhost`/`127.0.0.1`). It does **not** disable ATS for public internet connections, so it's much more targeted than `NSAllowsArbitraryLoads`.

### When Users Connect Remotely

If users connect to their server over the internet (via ngrok, Cloudflare Tunnel, or Tailscale), those connections will typically be HTTPS, so ATS is satisfied automatically. The only scenario where you'd need broader ATS exceptions is if someone runs their server on a public IP without TLS — which you should probably discourage anyway.

### App Store Review Consideration

`NSAllowsLocalNetworking` is generally accepted by App Store review without justification, since it's the standard approach for IoT and local server communication apps. It's far less likely to cause review friction than `NSAllowsArbitraryLoads`.

---

## Cancellation (The Stop Button)

The cancellation chain works like this:

1. User taps **Stop** → `viewModel.stopGenerating()` → `streamTask?.cancel()`
2. The `Task` being cancelled causes `Task.checkCancellation()` to throw `CancellationError` (or the `for try await` loop to throw it at its next suspension point).
3. The `AsyncThrowingStream`'s `onTermination` handler fires, calling `task.cancel()` on the inner Task that holds the URLSession byte stream.
4. URLSession cancels the underlying HTTP connection.

The ViewModel's `catch is CancellationError` block commits whatever text has been streamed so far as a partial assistant message, so the user doesn't lose the response.

---

## Edge Cases & Gotchas

### 1. Varying SSE Formats Across Servers

Not all servers format SSE identically:

- **LM Studio**: Standard `data: {json}\n\n` format with `data: [DONE]` terminator.
- **Ollama** (OpenAI compat mode): Same format, but may include extra whitespace.
- **llama.cpp**: Standard format. Some older versions may omit the space after `data:`, sending `data:{json}` — hence the parser handles both `data: ` and `data:`.
- **vLLM**: Standard format. Known to send `data:[DONE]` without a space before `[DONE]`.

The parser should be lenient: trim whitespace from payloads, handle both `data: ` and `data:` prefixes.

### 2. Multi-line `data:` Fields

The SSE spec allows multi-line data fields (multiple consecutive `data:` lines that get concatenated). In practice, OpenAI-compatible servers don't use this — each chunk is a single `data:` line. But if you want to be spec-compliant, you'd need to buffer consecutive `data:` lines and join them with newlines before parsing as JSON. For an MVP targeting local LLM servers, this is unnecessary.

### 3. Empty `content` Fields

The first chunk often has `delta: { "role": "assistant" }` with no `content` field. Some chunks may have `delta: {}` (empty delta, typically the final chunk with a `finish_reason`). The parser must handle `content` being `nil` gracefully — just skip those chunks.

### 4. `finish_reason` Values

The `finish_reason` field tells you *why* the model stopped:

| Value | Meaning |
|---|---|
| `null` | Still generating |
| `"stop"` | Model reached a natural stop point or hit a stop sequence |
| `"length"` | Hit `max_tokens` limit — response was truncated |

When `finish_reason` is `"length"`, you might want to surface this to the user (e.g., "Response was truncated due to token limit").

### 5. Timeout Configuration

Local LLMs have highly variable time-to-first-token (TTFT) depending on:

- Model size and quantization
- Prompt length (longer prompts take longer to process)
- Whether the model was already loaded in memory or needs to be loaded from disk
- GPU vs. CPU inference

A 120-second `timeoutInterval` on the URLRequest is reasonable. Note that `timeoutInterval` in URLSession is the *idle* timeout (time between receiving data packets), not a total request timeout. Once tokens start flowing, the timeout resets with each chunk. The risk is only during the initial prompt-processing phase before the first token arrives.

For a truly generous approach, you could use a custom `URLSessionConfiguration`:

```swift
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 300  // 5 minutes idle timeout
config.timeoutIntervalForResource = 600 // 10 minutes total
let session = URLSession(configuration: config)
```

### 6. Connection Dropped Mid-Stream

If the server crashes, the Mac goes to sleep, or Wi-Fi drops mid-generation, the `for try await` loop will throw a `URLError`. The ViewModel should catch this and commit whatever partial text has been accumulated, rather than discarding it.

### 7. Rapid UI Updates & Performance

Each token yield triggers a SwiftUI view update via `@Published`. For fast models (50+ tokens/second), this means 50+ view updates per second. In practice this is fine for a `Text` view displaying a string, but could be problematic if you're doing expensive Markdown rendering on every update.

Mitigation strategies:
- **Batch updates**: Accumulate tokens in a buffer and flush to `@Published` on a timer (e.g., every 50ms). This caps updates at ~20/second.
- **Defer Markdown rendering**: Display raw text during streaming, render Markdown only after generation completes.
- **Use `Text` directly**: SwiftUI's `Text` is highly optimized for string updates. Avoid wrapping it in complex view hierarchies during streaming.

```swift
// Example: Batched updates using a timer
private var tokenBuffer = ""
private var flushTimer: Timer?

func startBatching() {
    flushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        Task { @MainActor in
            if !self.tokenBuffer.isEmpty {
                self.streamingText += self.tokenBuffer
                self.tokenBuffer = ""
            }
        }
    }
}
```

### 8. `bytes.lines` vs Manual Byte Parsing

`bytes.lines` handles line buffering for you, splitting on `\n`, `\r\n`, or `\r`. This covers all the line-ending formats the SSE spec defines. You don't need to manually buffer bytes and scan for delimiters.

One caveat: `bytes.lines` strips the line terminators, so you get clean strings. This is exactly what you want for SSE parsing.

---

## Model Discovery

Before chatting, the app needs to know what models are available. This is a simple non-streaming GET:

```swift
func fetchModels(baseURL: String, apiKey: String? = nil) async throws -> [ModelList.Model] {
    guard let url = URL(string: "\(baseURL)/models") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 10

    if let apiKey = apiKey, !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
    }

    let modelList = try JSONDecoder().decode(ModelList.self, from: data)
    return modelList.data
}
```

This can be called when the user adds/selects a server to populate the model picker.

---

## Dependency Summary

| Component | Source | Notes |
|---|---|---|
| URLSession | Foundation (built-in) | Available iOS 15+ for `bytes(for:)` |
| JSONEncoder/Decoder | Foundation (built-in) | |
| AsyncThrowingStream | Swift stdlib | Available Swift 5.5+ |
| SwiftUI | Apple framework | |

**Total third-party dependencies: zero.**

The entire networking and SSE parsing layer can be built with Foundation alone. The SSE format from OpenAI-compatible servers is simple enough that a full SSE library (like `EventSource` by Mattt) is unnecessary — though it could be pulled in later if you need full SSE spec compliance (event types, retry intervals, reconnection).

---

## Testing Strategy

Since you practice TDD, here's how the components break down for testing:

### Unit-testable without network

- **SSE line parser** (`parseSSELine`): Pure function, trivial to test with string inputs. Test cases: valid data lines, `[DONE]`, empty lines, comments, malformed JSON, missing content field, `data:` without space.
- **Codable models**: Test decoding from fixture JSON strings. Include chunks with `content`, chunks with only `role`, chunks with `finish_reason`, chunks with `usage`.
- **Request builder**: Verify URL construction, headers, body encoding. Test with and without API key.

### Integration-testable with mock server

- **StreamingChatClient**: Use a local HTTP server (or `URLProtocol` subclass) that emits pre-recorded SSE responses. Test normal completion, cancellation mid-stream, HTTP errors, malformed SSE, connection drops.

### UI-testable

- **ChatViewModel**: Inject a mock `StreamingChatClient`. Verify that `streamingText` accumulates tokens, `isStreaming` toggles correctly, cancellation commits partial text, errors are surfaced.

---

## File Checklist for Implementation

```
Services/
├── StreamingChatClient.swift     # AsyncThrowingStream wrapper around URLSession
├── SSEParser.swift               # parseSSELine() and SSEEvent enum
├── OpenAIModels.swift            # All Codable request/response types
├── RequestBuilder.swift          # URLRequest construction
└── ModelDiscovery.swift          # GET /v1/models

ViewModels/
└── ChatViewModel.swift           # @MainActor, @Published, Task management

Tests/
├── SSEParserTests.swift
├── OpenAIModelsDecodingTests.swift
├── RequestBuilderTests.swift
└── ChatViewModelTests.swift
```

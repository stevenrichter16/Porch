import Foundation
@testable import Porch

enum MockURLProtocolError: LocalizedError {
    case missingHandler

    var errorDescription: String? {
        switch self {
        case .missingHandler:
            "MockURLProtocol is missing a request handler."
        }
    }
}

struct MockURLProtocolResponse: @unchecked Sendable {
    let statusCode: Int
    let headers: [String: String]
    let bodyChunks: [Data]
    let delayNanoseconds: UInt64
    let completionError: (any Error)?

    static func data(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> Self {
        Self(
            statusCode: statusCode,
            headers: headers,
            bodyChunks: [body],
            delayNanoseconds: 0,
            completionError: nil
        )
    }

    static func stream(
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "text/event-stream"],
        bodyChunks: [Data],
        delayNanoseconds: UInt64 = 0,
        completionError: (any Error)? = nil
    ) -> Self {
        Self(
            statusCode: statusCode,
            headers: headers,
            bodyChunks: bodyChunks,
            delayNanoseconds: delayNanoseconds,
            completionError: completionError
        )
    }
}

final class MockURLProtocol: URLProtocol {
    typealias RequestHandler = (URLRequest) throws -> MockURLProtocolResponse

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requestHandler: RequestHandler?
        var requests: [URLRequest] = []
        var deliveredChunkCount = 0
        var onChunkDelivered: (@Sendable (Int) -> Void)?
    }

    private static let state = State()

    private var loadingTask: Task<Void, Never>?
    private let completionLock = NSLock()
    private var hasCompleted = false

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let currentRequest = requestByConsumingBodyStream(from: request)
        let handler = Self.withLockedState { state in
            state.requests.append(currentRequest)
            return state.requestHandler
        }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: MockURLProtocolError.missingHandler)
            return
        }

        do {
            let response = try handler(currentRequest)
            loadingTask = Task { [weak self] in
                await self?.deliver(response, for: currentRequest)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
        loadingTask = nil
        completeIfNeeded(with: URLError(.cancelled))
    }

    static func reset() {
        withLockedState { state in
            state.requestHandler = nil
            state.requests = []
            state.deliveredChunkCount = 0
            state.onChunkDelivered = nil
        }
    }

    static func setRequestHandler(_ handler: @escaping RequestHandler) {
        withLockedState { state in
            state.requestHandler = handler
            state.requests = []
            state.deliveredChunkCount = 0
            state.onChunkDelivered = nil
        }
    }

    static func setChunkObserver(_ observer: (@Sendable (Int) -> Void)?) {
        withLockedState { state in
            state.onChunkDelivered = observer
        }
    }

    static var capturedRequests: [URLRequest] {
        withLockedState { state in
            state.requests
        }
    }

    static var deliveredChunkCount: Int {
        withLockedState { state in
            state.deliveredChunkCount
        }
    }

    private func deliver(_ response: MockURLProtocolResponse, for request: URLRequest) async {
        guard let client else { return }

        let url = request.url ?? URL(string: "https://example.invalid")!
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        ) else {
            client.urlProtocol(self, didFailWithError: StreamError.invalidResponse)
            return
        }

        client.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

        do {
            for chunk in response.bodyChunks {
                try Task.checkCancellation()
                if response.delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: response.delayNanoseconds)
                }
                if !chunk.isEmpty {
                    let deliveredChunkCount = Self.withLockedState { state in
                        state.deliveredChunkCount += 1
                        return state.deliveredChunkCount
                    }
                    client.urlProtocol(self, didLoad: chunk)
                    Self.withLockedState { state in
                        state.onChunkDelivered?(deliveredChunkCount)
                    }
                }
            }

            if let completionError = response.completionError {
                completeIfNeeded(with: completionError)
            } else {
                finishIfNeeded()
            }
        } catch is CancellationError {
            return
        } catch {
            completeIfNeeded(with: error)
        }
    }

    private static func withLockedState<T>(_ action: (State) -> T) -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        return action(state)
    }

    private func requestByConsumingBodyStream(from request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let bodyStream = request.httpBodyStream else {
            return request
        }

        var requestWithBody = request
        requestWithBody.httpBody = readData(from: bodyStream)
        return requestWithBody
    }

    private func readData(from stream: InputStream) -> Data {
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        stream.open()
        defer { stream.close() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                return data
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data
    }

    private func finishIfNeeded() {
        completionLock.lock()
        let shouldComplete = !hasCompleted
        hasCompleted = true
        completionLock.unlock()

        guard shouldComplete else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func completeIfNeeded(with error: any Error) {
        completionLock.lock()
        let shouldComplete = !hasCompleted
        hasCompleted = true
        completionLock.unlock()

        guard shouldComplete else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }
}

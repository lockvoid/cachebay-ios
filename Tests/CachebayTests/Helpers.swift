import Foundation
import Cachebay

/// Minimal in-memory HTTP transport for tests. Maps a query string (or substring)
/// to a canned `OperationResult<JSONValue>`. Also records the sequence of calls
/// so assertions can verify network behaviour.
public final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct Call: Sendable {
        public let query: String
        public let variables: [String: JSONValue]
    }

    private let lock = NSLock()
    private var responses: [(matcher: String, provider: @Sendable ([String: JSONValue]) -> OperationResult<JSONValue>)] = []
    private(set) public var calls: [Call] = []

    public init() {}

    public func whenQueryContains(_ needle: String, respondWith data: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        responses.append((needle, { _ in OperationResult(data: data) }))
    }

    public func whenQueryContains(_ needle: String, respond: @escaping @Sendable ([String: JSONValue]) -> OperationResult<JSONValue>) {
        lock.lock(); defer { lock.unlock() }
        responses.append((needle, respond))
    }

    public func execute(_ context: HTTPContext) async throws -> OperationResult<JSONValue> {
        let matchers = recordCall(context)
        for (needle, provider) in matchers {
            if context.query.contains(needle) { return provider(context.variables) }
        }
        return OperationResult(data: nil, error: CombinedError(networkMessage: "No mock for \(context.query)"))
    }

    private func recordCall(_ context: HTTPContext) -> [(matcher: String, provider: @Sendable ([String: JSONValue]) -> OperationResult<JSONValue>)] {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(query: context.query, variables: context.variables))
        return responses
    }
}

public final class MockWSTransport: WSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSONValue] = []
    public init(frames: [JSONValue] = []) { self.frames = frames }

    public func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        let frames = self.frames
        return AsyncThrowingStream { continuation in
            Task { @Sendable in
                for f in frames { continuation.yield(OperationResult(data: f)) }
                continuation.finish()
            }
        }
    }
}

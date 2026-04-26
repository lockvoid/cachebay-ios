import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// WSTransport implementing the `graphql-transport-ws` subprotocol over
/// `URLSessionWebSocketTask`. Connection is shared across subscriptions —
/// init handshake runs lazily on first `subscribe` call.
///
/// Messages:
///   → {type: "connection_init", payload: {...}}
///   ← {type: "connection_ack"}
///   → {id, type: "subscribe", payload: {query, variables}}
///   ← {id, type: "next", payload: {data, errors}}
///   ← {id, type: "error", payload: [{message}]}
///   ← {id, type: "complete"}
///   → {id, type: "complete"}  // cancel
public final class URLSessionWebSocketTransport: WSTransport, @unchecked Sendable {
    public let url: URL
    public let session: URLSession
    public var connectionParams: [String: JSONValue]
    public var subprotocol: String

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var acked = false
    private var ackContinuations: [CheckedContinuation<Void, Error>] = []
    private var handlers: [String: @Sendable (WSServerMessage) -> Void] = [:]
    private var idCounter: UInt64 = 0

    public init(
        url: URL,
        session: URLSession = .shared,
        subprotocol: String = "graphql-transport-ws",
        connectionParams: [String: JSONValue] = [:]
    ) {
        self.url = url
        self.session = session
        self.subprotocol = subprotocol
        self.connectionParams = connectionParams
    }

    public func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        let id = nextID()
        let query = context.query
        let variables = context.variables
        return AsyncThrowingStream<OperationResult<JSONValue>, Error> { (continuation: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation) in
            let selfRef = self
            Task { @Sendable in
                do {
                    try await selfRef.ensureConnected()
                    selfRef.registerHandler(id: id) { msg in
                        switch msg.type {
                        case "next":
                            if let payload = msg.payload {
                                let data = payload["data"] ?? .null
                                var errors: [GraphQLResponseError] = []
                                if case .array(let arr) = payload["errors"] ?? .null {
                                    for item in arr {
                                        if case .object(let o) = item {
                                            errors.append(GraphQLResponseError(message: o["message"]?.string ?? "GraphQL error"))
                                        }
                                    }
                                }
                                let err: CombinedError? = errors.isEmpty ? nil : CombinedError(graphqlErrors: errors)
                                if case .null = data {
                                    continuation.yield(OperationResult<JSONValue>(data: nil, error: err))
                                } else {
                                    continuation.yield(OperationResult<JSONValue>(data: data, error: err))
                                }
                            }
                        case "error":
                            var errors: [GraphQLResponseError] = []
                            if case .array(let arr) = msg.rawPayload ?? .null {
                                for item in arr {
                                    if case .object(let o) = item {
                                        errors.append(GraphQLResponseError(message: o["message"]?.string ?? "GraphQL error"))
                                    }
                                }
                            }
                            continuation.finish(throwing: CombinedError(graphqlErrors: errors))
                        case "complete":
                            continuation.finish()
                        default: break
                        }
                    }
                    try await selfRef.send(.subscribe(id: id, query: query, variables: variables))
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                Task { @Sendable in
                    selfRef.unregisterHandler(id: id)
                    try? await selfRef.send(.complete(id: id))
                }
            }
        }
    }

    // MARK: - Connection management

    private func ensureConnected() async throws {
        switch takeConnectionState() {
        case .alreadyAcked:
            return
        case .alreadyConnecting:
            try await waitForAck()
            return
        case .startConnect(let ws):
            ws.resume()
            let selfRef = self
            receiveTask = Task { @Sendable in
                await selfRef.receiveLoop(task: ws)
            }
            try await send(.connectionInit(connectionParams))
            try await waitForAck()
        }
    }

    private enum ConnectionDecision {
        case alreadyAcked
        case alreadyConnecting
        case startConnect(URLSessionWebSocketTask)
    }

    private func takeConnectionState() -> ConnectionDecision {
        lock.lock(); defer { lock.unlock() }
        if acked { return .alreadyAcked }
        if task != nil { return .alreadyConnecting }
        var req = URLRequest(url: url)
        req.setValue(subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let ws = session.webSocketTask(with: req)
        task = ws
        return .startConnect(ws)
    }

    private func waitForAck() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if acked {
                lock.unlock()
                cont.resume()
            } else {
                ackContinuations.append(cont)
                lock.unlock()
            }
        }
    }

    private func registerHandler(id: String, handler: @escaping @Sendable (WSServerMessage) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = handler
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let s):
                    guard let data = s.data(using: .utf8) else { continue }
                    dispatch(data)
                case .data(let d):
                    dispatch(d)
                @unknown default: break
                }
            } catch {
                dispatchError(error)
                return
            }
        }
    }

    private func dispatch(_ data: Data) {
        guard let value = try? JSONValue.from(json: data),
              case .object(let obj) = value,
              let type = obj["type"]?.string
        else { return }
        let id = obj["id"]?.string
        let payload: [String: JSONValue]? = {
            if case .object(let p) = obj["payload"] ?? .null { return p }
            return nil
        }()
        let rawPayload = obj["payload"]

        if type == "connection_ack" {
            lock.lock()
            acked = true
            let conts = ackContinuations
            ackContinuations.removeAll()
            lock.unlock()
            for c in conts { c.resume() }
            return
        }

        let msg = WSServerMessage(id: id, type: type, payload: payload, rawPayload: rawPayload)
        lock.lock()
        let handler = id.flatMap { handlers[$0] }
        lock.unlock()
        handler?(msg)
    }

    private func dispatchError(_ error: Error) {
        lock.lock()
        let conts = ackContinuations
        ackContinuations.removeAll()
        let allHandlers = handlers
        handlers.removeAll()
        lock.unlock()
        for c in conts { c.resume(throwing: error) }
        for (_, h) in allHandlers {
            h(WSServerMessage(id: nil, type: "error", payload: nil, rawPayload: nil))
        }
    }

    private func unregisterHandler(id: String) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    private func nextID() -> String {
        lock.lock(); defer { lock.unlock() }
        idCounter += 1
        return "sub-\(idCounter)"
    }

    private func send(_ message: WSClientMessage) async throws {
        let data = try JSONSerialization.data(withJSONObject: message.toFoundation())
        guard let str = String(data: data, encoding: .utf8) else { throw CachebayError.networkError("WS encode failed") }
        guard let task else { throw CachebayError.networkError("WS not connected") }
        try await task.send(.string(str))
    }
}

// MARK: - Messages

struct WSServerMessage: Sendable {
    let id: String?
    let type: String
    let payload: [String: JSONValue]?
    let rawPayload: JSONValue?
}

enum WSClientMessage: Sendable {
    case connectionInit([String: JSONValue])
    case subscribe(id: String, query: String, variables: [String: JSONValue])
    case complete(id: String)

    func toFoundation() -> [String: Any] {
        switch self {
        case .connectionInit(let params):
            return ["type": "connection_init", "payload": JSONValue.object(params).toFoundation()]
        case .subscribe(let id, let query, let variables):
            return [
                "id": id,
                "type": "subscribe",
                "payload": [
                    "query": query,
                    "variables": JSONValue.object(variables).toFoundation(),
                ]
            ]
        case .complete(let id):
            return ["id": id, "type": "complete"]
        }
    }
}

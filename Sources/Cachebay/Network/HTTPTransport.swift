import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTPTransport backed by `URLSession`. Sends GraphQL requests as
/// POST `application/json` bodies with `{query, variables}` and parses the
/// `{data, errors}` response.
public struct URLSessionHTTPTransport: HTTPTransport {
    public let url: URL
    public let session: URLSession
    public var headers: [String: String]
    public var requestModifier: (@Sendable (_ request: inout URLRequest) -> Void)?

    /// Optional profiler — when present, the JSON decode step of each
    /// response gets its own `cachebay.transport.http.decode` span. The
    /// wire RTT itself is intentionally NOT measured (server time isn't
    /// Cachebay's optimisation target); only the decode work that
    /// actually runs on the Cachebay side is timed.
    public let profiler: (any CachebayProfiler)?

    public init(
        url: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:],
        requestModifier: (@Sendable (_ request: inout URLRequest) -> Void)? = nil,
        profiler: (any CachebayProfiler)? = nil
    ) {
        self.url = url
        self.session = session
        self.headers = headers
        self.requestModifier = requestModifier
        self.profiler = profiler
    }

    public func execute(_ context: HTTPContext) async throws -> OperationResult<JSONValue> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        requestModifier?(&request)

        let body: [String: Any] = [
            "query": context.query,
            "variables": JSONValue.object(context.variables).toFoundation(),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                return OperationResult(data: nil, error: CombinedError(networkMessage: "HTTP \(http.statusCode): \(body)"))
            }
            // Decode the response body — Cachebay's work, not the server's.
            // Wire RTT is excluded by the parent `executeQuery` span's
            // `excludingHost { ... }` wrapper; this span captures only
            // the parse + extract step. Useful when consumers see large
            // `firstEmit` durations and need to know whether the response
            // size is dominating before any normalize work begins.
            let decodeSpan = profiler?.begin("cachebay.transport.http.decode")
            decodeSpan?.attribute("bytes", "\(data.count)")
            let parsed = try JSONValue.from(json: data)
            let payloadData = parsed["data"] ?? .null
            let graphqlErrors = parseGraphQLErrors(parsed["errors"])
            decodeSpan?.end()
            let err: CombinedError? = graphqlErrors.isEmpty ? nil : CombinedError(graphqlErrors: graphqlErrors)
            if case .null = payloadData {
                return OperationResult(data: nil, error: err)
            }
            return OperationResult(data: payloadData, error: err)
        } catch {
            return OperationResult(data: nil, error: CombinedError(networkError: error))
        }
    }

    private func parseGraphQLErrors(_ v: JSONValue?) -> [GraphQLResponseError] {
        guard case .array(let arr) = v ?? .null else { return [] }
        var out: [GraphQLResponseError] = []
        for item in arr {
            guard case .object(let o) = item else { continue }
            let message = o["message"]?.string ?? "Unknown GraphQL error"
            var path: [String]? = nil
            if case .array(let a) = o["path"] ?? .null {
                path = a.compactMap { $0.string ?? $0.int.map { String($0) } }
            }
            var locations: [GraphQLResponseError.Location]? = nil
            if case .array(let a) = o["locations"] ?? .null {
                locations = a.compactMap {
                    guard case .object(let l) = $0,
                          let line = l["line"]?.int,
                          let col = l["column"]?.int
                    else { return nil }
                    return .init(line: Int(line), column: Int(col))
                }
            }
            var ext: [String: JSONValue]? = nil
            if case .object(let e) = o["extensions"] ?? .null { ext = e }
            out.append(GraphQLResponseError(message: message, path: path, locations: locations, extensions: ext))
        }
        return out
    }
}

#if canImport(FoundationNetworking)
// Linux/Foundation stubs URLSession.data(for:); provide a bridge when necessary.
extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = self.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let data, let response else {
                    cont.resume(throwing: URLError(.badServerResponse)); return
                }
                cont.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}
#endif

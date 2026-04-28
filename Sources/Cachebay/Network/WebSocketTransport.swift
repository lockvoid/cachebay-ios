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
///
/// ## Auto-reconnect
///
/// When the socket drops unexpectedly (server crash, network blip,
/// app suspended/resumed), the transport schedules a reconnect with
/// exponential backoff (configurable via `ReconnectPolicy`).
/// Subscription continuations are kept alive across the reconnect:
/// after `connection_ack` lands on the new socket, every active
/// subscription's `subscribe` message is replayed automatically. The
/// stream a subscriber holds doesn't error or finish — it just stops
/// yielding for the duration of the gap, then resumes.
///
/// One-shot WS operations (queries / mutations over WS — uncommon, but
/// supported by the protocol) are not retried. Only subscriptions
/// survive. In practice cachebay routes queries/mutations over HTTP
/// so this distinction never matters.
///
/// Branch-1 immediate reconnect (network back, app foregrounded) is
/// **not** built into the transport — call `reconnect()` from your
/// own `NWPathMonitor` / `UIApplication.didBecomeActiveNotification`
/// handlers. The transport is platform-agnostic on purpose; see
/// `Docs/SUBSCRIPTIONS.md` for a copy-paste consumer wiring example.
///
/// Observability:
///   - `state` — synchronous read of the current `ConnectionState`.
///   - `events()` — `AsyncStream<ConnectionEvent>` of lifecycle events
///     (connecting/acked/messageSent/messageReceived/disconnected/
///     reconnectScheduled/stopped). Single subscriber per call;
///     calling again returns a fresh stream attached to all events
///     from that point forward.
///   - `disconnect(reason:)` — explicit teardown. Puts the transport
///     in `.stopped(.userClosed)` — auto-reconnect is OFF until
///     `reconnect()` is called.
///   - `reconnect()` — state-aware caller-driven reconnect.
public final class URLSessionWebSocketTransport: WSTransport, @unchecked Sendable {
    public let url: URL
    public let session: URLSession
    /// Snapshot of the params sent in `connection_init`. Read-only;
    /// mutate via `updateConnectionParams(_:reconnectIfConnected:)` so
    /// the change is synchronized with the connection lifecycle.
    public var connectionParams: [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return _connectionParams
    }
    private var _connectionParams: [String: JSONValue]
    public var subprotocol: String
    public let reconnectPolicy: ReconnectPolicy
    /// Optional client-initiated keepalive cadence. When non-nil, the
    /// transport sends a `{"type":"ping"}` frame at this interval after
    /// `connection_ack` lands. Useful for long-idle subscriptions
    /// behind NAT (typical NAT timeout: 60–120s) and proxies with idle
    /// disconnect policies. Default `nil` (off) — costs one tiny frame
    /// per interval; only worth it for apps that hold subscriptions
    /// across long quiet periods on cellular/WiFi.
    public let pingInterval: Duration?
    /// Clock used for backoff sleeps. Tests inject a fake clock to
    /// drive deterministic time advancement; production uses
    /// `ContinuousClock` (real wall-clock).
    public let clock: any Clock<Duration>

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectorTask: Task<Void, Never>?
    private var backoffSleepTask: Task<Void, Never>?
    private var pingTimerTask: Task<Void, Never>?
    private var acked = false
    private var ackContinuations: [CheckedContinuation<Void, Error>] = []
    private var subscriptions: [String: ActiveSubscription] = [:]
    private var idCounter: UInt64 = 0
    private var _state: ConnectionState = .disconnected
    private var attemptCounter: Int = 0
    private var eventContinuation: AsyncStream<ConnectionEvent>.Continuation?
    private var eventContinuationToken: UUID?

    public init(
        url: URL,
        session: URLSession? = nil,
        subprotocol: String = "graphql-transport-ws",
        connectionParams: [String: JSONValue] = [:],
        reconnectPolicy: ReconnectPolicy = .default,
        pingInterval: Duration? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.url = url
        self.session = session ?? Self.makeDefaultSession()
        self.subprotocol = subprotocol
        self._connectionParams = connectionParams
        self.reconnectPolicy = reconnectPolicy
        self.pingInterval = pingInterval
        self.clock = clock
    }

    /// Default WS-specific connect timeout (seconds) used when the
    /// caller doesn't pass an explicit `URLSession`.
    ///
    /// Why 10s:
    ///   - Greater than `ReconnectPolicy.default.maxDelay` (5s) so each
    ///     backoff cycle gets a full attempt instead of being cut short.
    ///   - Covers slow cold-start servers (k8s pod boot, fly.io machine
    ///     resume — typically 3–7s p95).
    ///   - Fails fast on half-connected sockets (TCP succeeded, WS
    ///     handshake stalled — the dominant failure mode during a
    ///     server-restart window). URLSession's 60s default for HTTPS
    ///     request/response would eat the entire backoff schedule.
    ///   - Industry-aligned: AWS SDK uses 5s WS connect, Cloudflare
    ///     expects WS handshake <10s, Slack/Discord clients ~10s.
    public static let defaultConnectTimeout: TimeInterval = 10

    /// Builds the default `URLSession` used when none is supplied. Tunes
    /// `timeoutIntervalForRequest` to `defaultConnectTimeout` so a stuck
    /// WS handshake fails fast instead of stalling for URLSession's
    /// 60s HTTP default.
    private static func makeDefaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = defaultConnectTimeout
        return URLSession(configuration: cfg)
    }

    // MARK: - Public observability surface

    /// Connection lifecycle as a snapshot. Safe to read from any context.
    ///
    /// `disconnected` is the brief in-between state before either a
    /// fresh connect or a scheduled reconnect attempt. `stopped` is
    /// the permanent end state — auto-reconnect won't run until
    /// `reconnect()` is called explicitly.
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case stopped(reason: TerminalReason)
    }

    /// Why the transport stopped retrying. Distinguishing the cases
    /// lets UI show "Reconnect" vs "Sign in again" vs "Tap to retry".
    public enum TerminalReason: Sendable, Equatable {
        case userClosed
        case unauthorized(code: Int)
        case maxAttemptsExceeded
    }

    /// Discrete lifecycle / message events. Consumers fold these into UI
    /// state, logs, telemetry, etc. Emitted in the order they happen on
    /// the wire.
    public enum ConnectionEvent: Sendable {
        case connecting
        case acked
        case messageSent(type: String, id: String?)
        case messageReceived(type: String, id: String?)
        case disconnected(reason: DisconnectReason)
        case reconnectScheduled(attempt: Int, delay: TimeInterval)
        case stopped(reason: TerminalReason)
    }

    /// Why a disconnect happened. `userClosed` is the explicit
    /// `disconnect()` path; the others are unexpected.
    public enum DisconnectReason: Sendable {
        case userClosed
        case receiveLoopError(Error)
        case sendError(Error)
    }

    public var state: ConnectionState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Single-subscriber stream of `ConnectionEvent`s. Calling `events()`
    /// again supersedes any prior stream (the prior continuation is
    /// finished). For multi-subscriber needs, wrap this in a single
    /// drainer that fans out (see `WSStateMonitor` in the demo).
    public func events() -> AsyncStream<ConnectionEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let token = UUID()
            lock.lock()
            let prior = eventContinuation
            eventContinuation = continuation
            eventContinuationToken = token
            lock.unlock()
            prior?.finish()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                if self.eventContinuationToken == token {
                    self.eventContinuation = nil
                    self.eventContinuationToken = nil
                }
                self.lock.unlock()
            }
        }
    }

    /// Explicit user-initiated teardown. Cancels every active
    /// subscription's stream with a finish, parks the transport in
    /// `.stopped(.userClosed)`. Auto-reconnect does NOT run from this
    /// state — call `reconnect()` to resume. Idempotent.
    public func disconnect(reason: DisconnectReason = .userClosed) {
        teardown(disconnectEvent: .disconnected(reason: reason),
                 then: .stopped(reason: .userClosed),
                 finishSubscriptions: true)
    }

    /// Replace the params sent in `connection_init`. Use this when
    /// rotating an auth token mid-session (refresh-token flow, account
    /// switch, role change) without manually wrangling
    /// `disconnect()` → reset → `reconnect()`.
    ///
    /// - Parameters:
    ///   - params: New params payload. Replaces the previous payload
    ///     wholesale (this is **not** a merge).
    ///   - reconnectIfConnected: When `true`, an active or in-flight
    ///     connection is dropped immediately and a fresh
    ///     `connection_init` (carrying `params`) is sent on a new
    ///     socket. Active subscriptions are preserved and replayed
    ///     after the new ack. When `false`, the params are stored and
    ///     take effect on the next natural reconnect — useful when you
    ///     know a reconnect is imminent (e.g. you've just received
    ///     `.disconnected` from `events()`).
    ///
    /// Inspired by Apollo iOS's `updateConnectingPayload(_:reconnectIfConnected:)`.
    public func updateConnectionParams(_ params: [String: JSONValue], reconnectIfConnected: Bool = false) {
        lock.lock()
        _connectionParams = params
        let snapshot = _state
        lock.unlock()

        guard reconnectIfConnected else { return }

        switch snapshot {
        case .connected, .connecting:
            // Tear the socket down and reconnect immediately so the
            // new params land in the next `connection_init`.
            // Subscriptions stay registered (as `.subscribed`) and are
            // replayed after the new ack.
            teardown(
                disconnectEvent: .disconnected(reason: .userClosed),
                then: .reconnecting(attempt: 0),
                finishSubscriptions: false
            )
            startReconnector(initialDelay: 0)
        case .reconnecting:
            // Already reconnecting — the next `ensureConnected()` will
            // pick up the new params. Wake any pending backoff sleep
            // so it happens sooner.
            wakeBackoffSleep()
        case .disconnected, .stopped:
            // Nothing live; new params take effect on the next
            // subscribe() / reconnect().
            break
        }
    }

    /// Caller-driven reconnect, state-aware:
    ///
    /// | Current state                    | Effect                                                                  |
    /// | -------------------------------- | ----------------------------------------------------------------------- |
    /// | `.connected`                     | no-op                                                                   |
    /// | `.connecting`                    | no-op (already trying)                                                  |
    /// | `.disconnected`                  | start a fresh connect attempt                                           |
    /// | `.reconnecting(N)`               | wake the pending backoff sleep, attempt now (counter unchanged)         |
    /// | `.stopped(_)`                    | reset attempt counter to 0, start a fresh connect; replays subscriptions |
    ///
    /// Idempotent — multiple concurrent calls collapse to one
    /// reconnect attempt. Used by:
    ///   * UI "Reconnect" buttons
    ///   * `NWPathMonitor.pathUpdateHandler` on `.satisfied`
    ///   * `UIApplication.didBecomeActiveNotification` observers
    public func reconnect() {
        lock.lock()
        let snapshot = _state
        let hasPending = !subscriptions.isEmpty
        lock.unlock()

        switch snapshot {
        case .connected, .connecting:
            return
        case .reconnecting:
            wakeBackoffSleep()
            return
        case .stopped:
            // Resurrect: reset attempt counter, kick off a fresh
            // connect-and-replay. If we have no pending subscriptions,
            // we still go to .disconnected so the next subscribe()
            // can lazily connect.
            lock.lock()
            attemptCounter = 0
            _state = hasPending ? .reconnecting(attempt: 0) : .disconnected
            lock.unlock()
            if hasPending { startReconnector(initialDelay: 0) }
            return
        case .disconnected:
            // Treat as resume: kick off connect immediately if there
            // are pending subscriptions, otherwise let lazy subscribe()
            // path handle it.
            if hasPending { startReconnector(initialDelay: 0) }
            return
        }
    }

    public func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        let id = nextID()
        let query = context.query
        let variables = context.variables
        return AsyncThrowingStream<OperationResult<JSONValue>, Error> { (continuation: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation) in
            let selfRef = self
            // Register the subscription in the registry — survives
            // reconnect, replays after connection_ack.
            let yield: @Sendable (OperationResult<JSONValue>) -> Void = { continuation.yield($0) }
            let finish: @Sendable (Error?) -> Void = { err in
                if let err { continuation.finish(throwing: err) } else { continuation.finish() }
            }
            selfRef.registerSubscription(id: id, query: query, variables: variables,
                                          yield: yield, finish: finish)

            Task { @Sendable in
                do {
                    try await selfRef.ensureConnected()
                    try await selfRef.send(.subscribe(id: id, query: query, variables: variables))
                    selfRef.markSubscriptionLive(id: id)
                } catch {
                    // First-attempt connect failure is terminal for
                    // THIS subscriber if we're already .stopped.
                    // Otherwise the reconnector will replay it.
                    if case .stopped = selfRef.state {
                        selfRef.unregisterSubscription(id: id)
                        continuation.finish(throwing: error)
                    }
                    // else: keep the entry; reconnector will replay
                    // when the socket comes back.
                }
            }

            continuation.onTermination = { _ in
                Task { @Sendable in
                    selfRef.unregisterSubscription(id: id)
                    try? await selfRef.send(.complete(id: id))
                }
            }
        }
    }

    // MARK: - Subscription registry

    /// Two-phase status mirroring Apollo iOS's
    /// `SubscriberRegistry.SubscriberInfo.status`. `.pending` entries
    /// have been registered by `subscribe()` but their caller-side
    /// Task hasn't sent the `subscribe` frame yet (it's parked in
    /// `waitForAck()`). `.subscribed` entries are on the wire — they
    /// get replayed on reconnect; `.pending` entries do **not**, because
    /// the awaiting Task will send the frame itself once `acked` flips.
    private enum SubscriptionStatus: Sendable { case pending, subscribed }

    private struct ActiveSubscription: Sendable {
        let id: String
        let query: String
        let variables: [String: JSONValue]
        let yield: @Sendable (OperationResult<JSONValue>) -> Void
        let finish: @Sendable (Error?) -> Void
        var status: SubscriptionStatus
    }

    private func registerSubscription(
        id: String,
        query: String,
        variables: [String: JSONValue],
        yield: @escaping @Sendable (OperationResult<JSONValue>) -> Void,
        finish: @escaping @Sendable (Error?) -> Void
    ) {
        lock.lock()
        subscriptions[id] = ActiveSubscription(id: id, query: query, variables: variables,
                                                yield: yield, finish: finish,
                                                status: .pending)
        lock.unlock()
    }

    private func markSubscriptionLive(id: String) {
        lock.lock()
        if var entry = subscriptions[id] {
            entry.status = .subscribed
            subscriptions[id] = entry
        }
        lock.unlock()
    }

    private func unregisterSubscription(id: String) {
        lock.lock()
        subscriptions.removeValue(forKey: id)
        lock.unlock()
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
            emit(.connecting)
            setState(.connecting)
            ws.resume()
            let selfRef = self
            receiveTask = Task { @Sendable in
                await selfRef.receiveLoop(task: ws)
            }
            try await send(.connectionInit(connectionParams))
            try await waitForAck()
        case .testSeamConnect:
            emit(.connecting)
            setState(.connecting)
            try await send(.connectionInit(connectionParams))
            try await waitForAck()
        }
    }

    private enum ConnectionDecision {
        case alreadyAcked
        case alreadyConnecting
        case startConnect(URLSessionWebSocketTask)
        /// Test-only: simulate a fresh handshake without opening a real
        /// socket. Mirrors `.startConnect` behaviour — emit `.connecting`,
        /// send `connection_init` to the outbound sink, park
        /// `waitForAck()` — but skips the URLSessionWebSocketTask wiring
        /// so the test isn't racing a real connect-attempt failure.
        case testSeamConnect
    }

    private func takeConnectionState() -> ConnectionDecision {
        lock.lock(); defer { lock.unlock() }
        if acked { return .alreadyAcked }
        if task != nil { return .alreadyConnecting }
        // Test seam: when an outbound sink is installed, callers have
        // staged state via `_testForceState` and a real
        // `URLSessionWebSocketTask` would just race the test. Drive the
        // handshake through the sink instead — `_testInjectInbound`
        // delivers the ack. Real production callers never set the sink
        // so this branch is unreachable outside `@testable` builds.
        if _outboundSinkStorage != nil {
            return .testSeamConnect
        }
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
                handleUnexpectedDisconnect(reason: .receiveLoopError(error))
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
            attemptCounter = 0  // reset on successful ack
            let conts = ackContinuations
            ackContinuations.removeAll()
            // Replay only `.subscribed` entries — these are leftovers
            // from a prior connection that need to be re-registered with
            // the server. `.pending` entries belong to callers whose
            // own Task is parked in `waitForAck()` and will send their
            // `subscribe` frame themselves once `acked` flips. Replaying
            // them here would duplicate the wire frame (and trip
            // close-code 4409 on strict servers).
            let toReplay = subscriptions.values.filter { $0.status == .subscribed }
            lock.unlock()
            setState(.connected)
            emit(.acked)
            for c in conts { c.resume() }

            for sub in toReplay {
                Task { @Sendable [self] in
                    try? await self.send(.subscribe(id: sub.id, query: sub.query, variables: sub.variables))
                }
            }

            startPingTimer()
            return
        }

        if type == "ping" {
            // Server-initiated ping. Spec: respond with pong so the
            // server knows we're alive.
            Task { @Sendable [self] in
                try? await self.send(.pong)
            }
            return
        }

        if type == "pong" {
            // Server's response to one of our pings. Liveness is
            // implicit (the receive loop didn't time out); nothing to
            // do beyond emitting the messageReceived event below.
            emit(.messageReceived(type: type, id: id))
            return
        }

        if type == "connection_error" {
            // Server-initiated permanent error during init handshake.
            // Stop retrying — caller has to refresh credentials and
            // call reconnect().
            stopWithTerminalReason(.unauthorized(code: 4400))
            return
        }

        emit(.messageReceived(type: type, id: id))

        let msg = WSServerMessage(id: id, type: type, payload: payload, rawPayload: rawPayload)

        guard let id, let sub = subscriptionFor(id: id) else { return }
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
                    sub.yield(OperationResult<JSONValue>(data: nil, error: err))
                } else {
                    sub.yield(OperationResult<JSONValue>(data: data, error: err))
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
            sub.finish(CombinedError(graphqlErrors: errors))
            unregisterSubscription(id: id)
        case "complete":
            sub.finish(nil)
            unregisterSubscription(id: id)
        default:
            break
        }
    }

    private func subscriptionFor(id: String) -> ActiveSubscription? {
        lock.lock(); defer { lock.unlock() }
        return subscriptions[id]
    }

    // MARK: - Disconnect / reconnect orchestration

    /// Unexpected disconnect from `receiveLoop` or `send` failure.
    /// Tears down the dead socket, then schedules an auto-reconnect
    /// if the policy allows.
    ///
    /// **No-ops** when we're already in a terminal `.stopped` state.
    /// This handles the race where `receiveLoop` catches a cancelled
    /// task error AFTER `stopWithTerminalReason` has already emitted
    /// `.stopped` and torn down — without this guard, the
    /// `setState(.disconnected)` below would corrupt the terminal
    /// state, and a stale `startReconnector` could spin up a fresh
    /// reconnect loop on a transport the caller has already given up on.
    private func handleUnexpectedDisconnect(reason: DisconnectReason) {
        lock.lock()
        if case .stopped = _state {
            lock.unlock()
            return
        }
        let pending = subscriptions
        let hasPending = !pending.isEmpty
        lock.unlock()

        // Always transition to `.disconnected` here, even when there
        // are pending subs the reconnector will pick up. A single
        // physical drop typically trips both the send path and the
        // receive-loop catch — without a torn-down state, the second
        // teardown's gate (line `task == nil && isAlreadyTornDown`)
        // doesn't match (`.connecting` isn't "torn down"), and the
        // duplicate `.disconnected` event slips through. The
        // reconnectorLoop overwrites to `.reconnecting(N)` on its
        // next iteration; the brief `.disconnected` flicker is fine.
        teardown(disconnectEvent: .disconnected(reason: reason),
                 then: .disconnected,
                 finishSubscriptions: false)

        // 4401/4403 detection from URLSessionWebSocketTask close codes:
        // URLSession surfaces them in the underlying error's userInfo.
        if let code = closeCode(from: reason), code == 4401 || code == 4403 {
            stopWithTerminalReason(.unauthorized(code: code))
            return
        }

        guard hasPending else {
            // Nothing to retry for. Stay in .disconnected; lazy
            // subscribe() will reconnect from scratch.
            setState(.disconnected)
            return
        }

        startReconnector(initialDelay: nil)
    }

    private func closeCode(from reason: DisconnectReason) -> Int? {
        let error: Error
        switch reason {
        case .userClosed: return nil
        case .receiveLoopError(let e): error = e
        case .sendError(let e): error = e
        }
        let nsError = error as NSError
        // URLSessionWebSocketTask close codes can show up in NSError
        // userInfo under either NSURLErrorFailingURLErrorKey-like keys
        // or directly in the code field.
        if nsError.domain == NSURLErrorDomain {
            // Custom 4xxx close codes don't map cleanly through
            // URLSession — best-effort detection.
            if let code = nsError.userInfo["NSURLSessionWebSocketCloseCode"] as? Int {
                return code
            }
        }
        return nil
    }

    /// Spawn the periodic ping Task. No-op when `pingInterval` is nil
    /// or when a timer is already running. Cancelled by `teardown()`.
    private func startPingTimer() {
        guard let interval = pingInterval else { return }
        lock.lock()
        if pingTimerTask != nil {
            lock.unlock()
            return
        }
        let selfRef = self
        let clockRef = self.clock
        pingTimerTask = Task { @Sendable in
            while !Task.isCancelled {
                do {
                    try await clockRef.sleep(for: interval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                try? await selfRef.send(.ping)
            }
        }
        lock.unlock()
    }

    /// Start (or restart) the reconnect orchestrator. If a reconnector
    /// is already running, this is a no-op — the existing one will
    /// continue. Pass `firstAttemptDelay: 0` to skip the first
    /// backoff (used by `reconnect()` to attempt immediately).
    private func startReconnector(initialDelay: TimeInterval?) {
        lock.lock()
        // Don't resurrect from a terminal state. Race window: a stale
        // `handleUnexpectedDisconnect` (delayed receiveLoopError from a
        // now-dead socket) can land here after `stopWithTerminalReason`
        // has nulled `reconnectorTask` and flipped state to `.stopped`.
        // Without this guard, the disconnect path would spawn a fresh
        // reconnector that emits one bonus `.reconnectScheduled` past
        // the terminal `.stopped` event — turning a 30%-flake test into
        // a deterministic pass. Public `reconnect()` resurrects state
        // OUT of `.stopped` before calling here, so it isn't blocked.
        if case .stopped = _state {
            lock.unlock()
            return
        }
        if reconnectorTask != nil {
            if initialDelay == 0 {
                lock.unlock()
                wakeBackoffSleep()
                return
            }
            lock.unlock()
            return
        }
        // Refuse to start if the policy disables auto-reconnect.
        if let max = reconnectPolicy.maxAttempts, max <= 0 {
            lock.unlock()
            stopWithTerminalReason(.maxAttemptsExceeded)
            return
        }
        let policy = reconnectPolicy
        reconnectorTask = Task { @Sendable [weak self] in
            await self?.reconnectorLoop(policy: policy, firstAttemptDelay: initialDelay)
        }
        lock.unlock()
    }

    private func reconnectorLoop(policy: ReconnectPolicy, firstAttemptDelay: TimeInterval?) async {
        var attempt = 0
        var firstAttempt = true

        while !Task.isCancelled {
            attempt += 1
            setReconnectingState(attempt: attempt)

            let delay: TimeInterval
            if firstAttempt, firstAttemptDelay == 0 {
                delay = 0
            } else {
                delay = computeBackoff(attempt: attempt, policy: policy)
            }
            firstAttempt = false

            if delay > 0 {
                emit(.reconnectScheduled(attempt: attempt, delay: delay))
                _ = await sleepInterruptibly(seconds: delay)
            }

            if Task.isCancelled { break }

            do {
                try await ensureConnected()
                // ensureConnected resolves once connection_ack lands.
                // The dispatch path resets attemptCounter and replays
                // pending subscriptions. We're done.
                clearReconnectorTask()
                return
            } catch {
                if let max = policy.maxAttempts, attempt >= max {
                    stopWithTerminalReason(.maxAttemptsExceeded)
                    return
                }
            }
        }
    }

    /// True for states where a follow-up disconnect event would be a
    /// duplicate (no live socket, already announced to observers).
    private func isAlreadyTornDown(_ state: ConnectionState) -> Bool {
        switch state {
        case .disconnected, .reconnecting, .stopped: return true
        case .connecting, .connected: return false
        }
    }

    private func setReconnectingState(attempt: Int) {
        lock.lock(); defer { lock.unlock() }
        attemptCounter = attempt
        _state = .reconnecting(attempt: attempt)
    }

    private func clearReconnectorTask() {
        lock.lock(); defer { lock.unlock() }
        reconnectorTask = nil
    }

    private func computeBackoff(attempt: Int, policy: ReconnectPolicy) -> TimeInterval {
        let base = policy.initialDelay * pow(policy.multiplier, Double(attempt - 1))
        let capped = min(base, policy.maxDelay)
        let lo = 1.0 - policy.jitter
        let hi = 1.0 + policy.jitter
        return capped * Double.random(in: lo...hi)
    }

    private func sleepInterruptibly(seconds: TimeInterval) async -> Bool {
        let duration: Duration = .nanoseconds(Int(max(0, seconds) * 1_000_000_000))
        let clock = self.clock
        let task: Task<Void, Never> = Task {
            do {
                try await clock.sleep(for: duration)
            } catch {
                // Cancelled — fall through; caller observes via task.isCancelled.
            }
        }
        installBackoffSleep(task)
        await task.value
        return !clearBackoffSleepReturningCancelledFlag(task)
    }

    private func installBackoffSleep(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        backoffSleepTask = task
    }

    /// Clears the stored sleep task and reports whether it was cancelled.
    /// Returning `true` means the sleep was woken early (cancellation
    /// is the wake-up mechanism for `wakeBackoffSleep`).
    private func clearBackoffSleepReturningCancelledFlag(_ task: Task<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cancelled = task.isCancelled
        backoffSleepTask = nil
        return cancelled
    }

    private func wakeBackoffSleep() {
        lock.lock()
        let t = backoffSleepTask
        lock.unlock()
        t?.cancel()
    }

    /// Park the transport in a permanent terminal state. Cancels any
    /// running reconnector, finishes every active subscription, emits
    /// a `.stopped` event. Caller has to call `reconnect()` to resume.
    private func stopWithTerminalReason(_ reason: TerminalReason) {
        lock.lock()
        reconnectorTask?.cancel()
        reconnectorTask = nil
        backoffSleepTask?.cancel()
        backoffSleepTask = nil
        let subs = subscriptions
        subscriptions.removeAll()
        _state = .stopped(reason: reason)
        lock.unlock()

        let resumeError = errorForTerminal(reason)
        for (_, sub) in subs { sub.finish(resumeError) }
        emit(.stopped(reason: reason))
    }

    private func errorForTerminal(_ reason: TerminalReason) -> Error {
        switch reason {
        case .userClosed:
            return CachebayError.networkError("WS disconnected (user closed)")
        case .unauthorized(let code):
            return CachebayError.networkError("WS unauthorized (close code \(code))")
        case .maxAttemptsExceeded:
            return CachebayError.networkError("WS reconnect attempts exhausted")
        }
    }

    /// Centralised teardown — drops the live socket and ack waiters,
    /// optionally finishes subscriptions, optionally moves to a
    /// follow-on state. Idempotent on an already-torn-down transport.
    ///
    /// Short-circuits when we're already in a non-live state
    /// (`disconnected` / `reconnecting` / `stopped`) AND there's no
    /// live socket — handles the dual-trigger case where the send
    /// path's error handler and the receive loop's error handler
    /// both fire for the same underlying disconnect, preventing
    /// duplicate `disconnected` events on the bus.
    private func teardown(
        disconnectEvent: ConnectionEvent,
        then nextState: ConnectionState?,
        finishSubscriptions: Bool
    ) {
        lock.lock()
        if task == nil && !finishSubscriptions, isAlreadyTornDown(_state) {
            lock.unlock()
            return
        }
        let conts = ackContinuations
        ackContinuations.removeAll()
        let prevTask = task
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        let prevPingTimer = pingTimerTask
        pingTimerTask = nil
        acked = false
        let subs = finishSubscriptions ? subscriptions : [:]
        if finishSubscriptions { subscriptions.removeAll() }
        if let nextState { _state = nextState }
        lock.unlock()

        prevPingTimer?.cancel()

        prevTask?.cancel(with: .normalClosure, reason: nil)

        let resumeError = CachebayError.networkError("WS disconnected")
        for c in conts { c.resume(throwing: resumeError) }
        if finishSubscriptions {
            for (_, sub) in subs { sub.finish(resumeError) }
        }
        emit(disconnectEvent)
        if case .stopped(let reason) = nextState {
            emit(.stopped(reason: reason))
        }
    }

    private func nextID() -> String {
        lock.lock(); defer { lock.unlock() }
        idCounter += 1
        return "sub-\(idCounter)"
    }

    private func send(_ message: WSClientMessage) async throws {
        if let sink = _testOutboundSink {
            sink(message)
            emit(message.eventForOutbound())
            return
        }
        let data = try JSONSerialization.data(withJSONObject: message.toFoundation())
        guard let str = String(data: data, encoding: .utf8) else { throw CachebayError.networkError("WS encode failed") }
        guard let task else { throw CachebayError.networkError("WS not connected") }
        do {
            try await task.send(.string(str))
        } catch {
            handleUnexpectedDisconnect(reason: .sendError(error))
            throw error
        }
        emit(message.eventForOutbound())
    }

    // MARK: - Test seams (internal — visible only via @testable)
    //
    // These let tests exercise specific state transitions and verify
    // wire-level behaviour without standing up a real WebSocket server.
    // They are NOT public API.

    /// Outbound-frame interceptor. When non-nil, frames bypass the live
    /// `URLSessionWebSocketTask` and are passed to the sink instead.
    /// `messageSent` is still emitted, so event-based assertions work
    /// the same as in production.
    internal var _testOutboundSink: (@Sendable (WSClientMessage) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _outboundSinkStorage }
        set { lock.lock(); _outboundSinkStorage = newValue; lock.unlock() }
    }
    private var _outboundSinkStorage: (@Sendable (WSClientMessage) -> Void)?

    /// Force the internal connection state. Tests use this to land in
    /// `.connecting` / `.reconnecting(N)` without actually opening a
    /// socket.
    internal func _testForceState(_ s: ConnectionState, acked: Bool) {
        lock.lock()
        _state = s
        self.acked = acked
        lock.unlock()
    }

    /// Feed an inbound JSON frame to the dispatch path. Equivalent to
    /// the receive loop reading a `String` message off the socket.
    internal func _testInjectInbound(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        dispatch(data)
    }

    /// Register a synthetic `.subscribed` subscription. Used by tests
    /// that need to simulate a pre-existing live subscription about to
    /// be replayed on reconnect.
    internal func _testRegisterSubscribed(id: String, query: String, variables: [String: JSONValue]) {
        lock.lock()
        subscriptions[id] = ActiveSubscription(
            id: id, query: query, variables: variables,
            yield: { _ in }, finish: { _ in },
            status: .subscribed
        )
        lock.unlock()
    }

    // MARK: - State / event helpers

    private func setState(_ newState: ConnectionState) {
        lock.lock()
        _state = newState
        lock.unlock()
    }

    private func emit(_ event: ConnectionEvent) {
        lock.lock()
        let cont = eventContinuation
        lock.unlock()
        cont?.yield(event)
    }
}

// MARK: - ReconnectPolicy

/// Configuration for `URLSessionWebSocketTransport`'s auto-reconnect
/// behavior. Defaults to enabled with tight exponential backoff
/// suited for real-time subscriptions:
///
/// - `initialDelay` 0.5s
/// - `multiplier` 2.0
/// - `maxDelay` 5s
/// - `jitter` ±30%
/// - `maxAttempts` nil (forever)
///
/// Sequence (with jitter): ~0.5s, 1s, 2s, 4s, 5s, 5s, 5s, …
///
/// 5s cap is what Phoenix / Pusher / similar real-time clients use —
/// a chat or live-update feed needs to recover within seconds, not
/// minutes. For HTTPS-style retry policies (where 30s+ caps make
/// sense), construct a custom `ReconnectPolicy` instead.
///
/// Use `.disabled` to opt out — the transport will surface
/// disconnects as terminal errors and not retry. Use `.aggressive`
/// for LAN/test scenarios where you want sub-second retries.
public struct ReconnectPolicy: Sendable {
    /// Backoff for the first retry attempt, in seconds.
    public var initialDelay: TimeInterval
    /// Cap on the per-attempt delay after exponential growth.
    public var maxDelay: TimeInterval
    /// Each subsequent attempt waits `previous * multiplier` seconds
    /// (capped by `maxDelay`).
    public var multiplier: Double
    /// Random factor applied to each computed delay; `0.3` means each
    /// delay is sampled from `[delay * 0.7, delay * 1.3]`. Prevents
    /// thundering-herd on synchronized client reconnects.
    public var jitter: Double
    /// Hard cap on total attempts. `nil` retries forever; `0`
    /// disables auto-reconnect entirely.
    public var maxAttempts: Int?

    public init(
        initialDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 5,
        multiplier: Double = 2.0,
        jitter: Double = 0.3,
        maxAttempts: Int? = nil
    ) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = jitter
        self.maxAttempts = maxAttempts
    }

    /// Default: 0.5s / 2× / 5s cap / ±30% jitter / forever.
    public static let `default`: ReconnectPolicy = ReconnectPolicy()

    /// Disable auto-reconnect entirely. Disconnects surface as
    /// terminal errors to active subscribers.
    public static let disabled: ReconnectPolicy = ReconnectPolicy(maxAttempts: 0)

    /// Tight retries for LAN/test environments — 50ms / 2× / 1s cap.
    /// Recovery within ~1s of the server coming back; useful for
    /// integration tests and tightly-controlled local networks.
    public static let aggressive: ReconnectPolicy = ReconnectPolicy(
        initialDelay: 0.05,
        maxDelay: 1,
        multiplier: 2.0,
        jitter: 0.1,
        maxAttempts: nil
    )
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
    case ping
    case pong

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
        case .ping:
            return ["type": "ping"]
        case .pong:
            return ["type": "pong"]
        }
    }

    func eventForOutbound() -> URLSessionWebSocketTransport.ConnectionEvent {
        switch self {
        case .connectionInit:           return .messageSent(type: "connection_init", id: nil)
        case .subscribe(let id, _, _):  return .messageSent(type: "subscribe", id: id)
        case .complete(let id):         return .messageSent(type: "complete", id: id)
        case .ping:                     return .messageSent(type: "ping", id: nil)
        case .pong:                     return .messageSent(type: "pong", id: nil)
        }
    }
}

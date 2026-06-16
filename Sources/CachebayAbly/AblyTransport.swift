import Foundation
import Ably
import Cachebay

// MARK: - Channel target

/// Where a GraphQL subscription listens on Ably.
///
/// Ably is generic pub/sub, not a `graphql-ws` socket, so the app maps each
/// subscription operation to a channel via `AblyTransport`'s `resolveChannel`
/// closure. Optionally pin a single message `name` to filter on, and Ably
/// channel `params` (e.g. `["rewind": "1"]` to replay the last message on
/// attach — useful so a subscriber that joins late still gets current state).
public struct AblyChannelTarget: Sendable {
    /// Ably channel name the server publishes this subscription's results to.
    public var name: String
    /// If set, only messages published with this `name` are delivered; `nil`
    /// delivers every message on the channel.
    public var eventName: String?
    /// Ably channel params (e.g. `["rewind": "1"]`). `nil` = channel defaults.
    public var params: [String: String]?

    public init(name: String, eventName: String? = nil, params: [String: String]? = nil) {
        self.name = name
        self.eventName = eventName
        self.params = params
    }
}

// MARK: - Transport

/// A Cachebay `WSTransport` backed by Ably realtime channels — for backends that
/// deliver GraphQL subscription results over Ably instead of a `graphql-ws`
/// socket.
///
/// **Auth (production best practice).** Construct an `ARTRealtime` configured
/// with `authCallback` (token auth) and pass it in via `init(realtime:…)`; never
/// ship an Ably API key in a client app. The transport never touches credentials
/// — it only attaches to channels and forwards messages.
///
/// **Channel mapping.** Ably has no notion of a GraphQL operation, so you supply
/// `resolveChannel` to map a `WSContext` (the subscription's `query` +
/// `variables`) to an `AblyChannelTarget`. The closure is `async throws`, so it
/// can do a server handshake first (e.g. POST the operation to your API and get
/// back the channel name) before returning.
///
/// **Frame contract.** Each Ably message payload is decoded to a `JSONValue` by
/// `decodeMessage` (default: parse `message.data` as JSON). If that value is a
/// GraphQL envelope (`{data, errors}`) it is split into
/// `OperationResult(data:error:)`; otherwise the whole payload becomes `data`.
/// Cachebay normalizes every yielded frame independently.
///
/// **Lifecycle.** A fatal Ably connection or channel state (`.failed`, e.g. an
/// expired token or denied capability) terminates the subscription stream with a
/// `CombinedError`. Transient states (`.disconnected` / `.suspended`) are *not*
/// surfaced — Ably reconnects and resumes automatically. When the consumer drops
/// the stream, the message listener is removed and (by default) the channel is
/// released once no subscriptions remain on it.
///
/// **Reconnect after continuity loss (presence backends).** Ably preserves
/// connection + channel + presence state for up to two minutes; a blip shorter
/// than that reattaches `resumed == true` with queued messages replayed and
/// presence intact — nothing to do. Past two minutes the connection goes
/// `suspended`; on recovery the channel reattaches `resumed == false` and
/// presence continuity is lost. A presence-based server (e.g. GraphQL Pro) will
/// have *reaped* the subscription during that window (its per-trigger
/// `presence.get` saw an empty set), so the dead channel never delivers again.
/// Re-entering presence can't revive a reaped record — only re-registering can.
/// So when `maintainsPresence` is set and a channel reattaches with
/// `resumed == false` (after its initial attach), the transport transparently
/// re-runs `resolveChannel` to register a fresh subscription on a new channel,
/// keeping the *same* `AsyncThrowingStream` alive. (Events the server broadcast
/// while we were gone are not replayed by a fresh subscription — recover those
/// app-side by refetching the backing query on reconnect.)
public final class AblyTransport: WSTransport, @unchecked Sendable {
    private let realtime: ARTRealtime
    private let ownsRealtime: Bool
    private let resolveChannel: @Sendable (WSContext) async throws -> AblyChannelTarget
    private let decodeMessage: @Sendable (ARTMessage) -> JSONValue?
    private let releaseChannelWhenIdle: Bool
    private let maintainsPresence: Bool

    // Channels are shared across subscriptions (`channels.get` returns the same
    // instance per name), so ref-count them and only release a channel once its
    // last subscription ends.
    private let lock = NSLock()
    private var channelRefCounts: [String: Int] = [:]

    /// Re-registration retry backoff bounds (continuity-loss recovery). The
    /// first retry is fast (we only get here right after the connection
    /// returned, so the registration POST should succeed); the cap keeps a
    /// pathological persistent failure from busy-looping.
    private static let reregisterInitialBackoff: UInt64 = 500_000_000      // 0.5s
    private static let reregisterMaxBackoff: UInt64 = 30_000_000_000       // 30s

    /// Use an Ably client **you** own and configured (recommended — you control
    /// `authCallback`, `clientId`, and the connection lifecycle).
    ///
    /// Set `maintainsPresence: true` for presence-based backends (e.g. GraphQL Pro,
    /// which reaps any subscription whose channel has no present member). The
    /// token must then carry the `presence` capability. Default `false` keeps the
    /// transport a plain pub/sub subscriber.
    public convenience init(
        realtime: ARTRealtime,
        resolveChannel: @escaping @Sendable (WSContext) async throws -> AblyChannelTarget,
        decodeMessage: @escaping @Sendable (ARTMessage) -> JSONValue? = AblyTransport.defaultDecodeMessage,
        releaseChannelWhenIdle: Bool = true,
        maintainsPresence: Bool = false
    ) {
        self.init(
            realtime: realtime, ownsRealtime: false,
            resolveChannel: resolveChannel, decodeMessage: decodeMessage,
            releaseChannelWhenIdle: releaseChannelWhenIdle, maintainsPresence: maintainsPresence)
    }

    /// Convenience: the transport builds and owns the `ARTRealtime` from
    /// `options` and closes it on `deinit`. Configure `options.authCallback` for
    /// token auth.
    public convenience init(
        options: ARTClientOptions,
        resolveChannel: @escaping @Sendable (WSContext) async throws -> AblyChannelTarget,
        decodeMessage: @escaping @Sendable (ARTMessage) -> JSONValue? = AblyTransport.defaultDecodeMessage,
        releaseChannelWhenIdle: Bool = true,
        maintainsPresence: Bool = false
    ) {
        self.init(
            realtime: ARTRealtime(options: options), ownsRealtime: true,
            resolveChannel: resolveChannel, decodeMessage: decodeMessage,
            releaseChannelWhenIdle: releaseChannelWhenIdle, maintainsPresence: maintainsPresence)
    }

    private init(
        realtime: ARTRealtime,
        ownsRealtime: Bool,
        resolveChannel: @escaping @Sendable (WSContext) async throws -> AblyChannelTarget,
        decodeMessage: @escaping @Sendable (ARTMessage) -> JSONValue?,
        releaseChannelWhenIdle: Bool,
        maintainsPresence: Bool
    ) {
        self.realtime = realtime
        self.ownsRealtime = ownsRealtime
        self.resolveChannel = resolveChannel
        self.decodeMessage = decodeMessage
        self.releaseChannelWhenIdle = releaseChannelWhenIdle
        self.maintainsPresence = maintainsPresence
    }

    deinit {
        if ownsRealtime { realtime.close() }
    }

    // MARK: WSTransport

    public func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        AsyncThrowingStream<OperationResult<JSONValue>, Error> { continuation in
            let sub = Subscription()

            // Channel resolution can be async (handshake), so set up off the
            // calling thread. The `Subscription` box is shared with onTermination.
            let setup = Task { [self] in
                do {
                    let target = try await resolveChannel(context)
                    if Task.isCancelled { return }

                    // Fatal connection failure → terminate this stream. Transient
                    // disconnect/suspend are left alone (Ably auto-recovers; a
                    // >2min suspend is handled per-channel via re-registration).
                    // Registered once for the subscription's lifetime — it spans
                    // channel swaps.
                    let connListener = realtime.connection.on { stateChange in
                        guard stateChange.current == .failed else { return }
                        continuation.finish(throwing: Self.error(from: stateChange.reason, fallback: "Ably connection failed"))
                    }
                    let stored = sub.withLock { () -> Bool in
                        guard !sub.cancelled else { return false }
                        sub.connectionListener = connListener
                        return true
                    }
                    guard stored else {
                        realtime.connection.off(connListener)
                        return
                    }

                    attachChannel(target, sub: sub, context: context, continuation: continuation)
                } catch {
                    continuation.finish(throwing: Self.error(from: error, fallback: "Ably subscribe failed"))
                }
            }
            sub.withLock { sub.setupTask = setup }

            continuation.onTermination = { [self] _ in teardown(sub) }
        }
    }

    // MARK: - Channel plumbing

    /// Establish the live wiring on `target`'s channel: message listener,
    /// channel-state listener (fatal-failure + continuity-loss handling), and —
    /// for presence backends — presence entry. Publishes the channel as the
    /// subscription's current one. Used for both the initial attach and each
    /// re-registration after continuity loss.
    private func attachChannel(
        _ target: AblyChannelTarget,
        sub: Subscription,
        context: WSContext,
        continuation: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation
    ) {
        // Build + wire Ably objects outside the box lock so we never hold it
        // across an Ably call. The state listener guards on channel identity, so
        // an event arriving before we publish the channel below is simply ignored.
        let channel = makeChannel(target)
        let decode = self.decodeMessage
        let onMessage: (ARTMessage) -> Void = { message in
            guard let frame = decode(message) else { return }
            continuation.yield(Self.result(from: frame))
        }
        let messageListener: ARTEventListener? = {
            if let eventName = target.eventName {
                return channel.subscribe(eventName, callback: onMessage)
            }
            return channel.subscribe(onMessage)
        }()
        let stateListener = channel.on { [self] stateChange in
            handleChannelState(stateChange, channel: channel, sub: sub, context: context, continuation: continuation)
        }

        var isFirstOnChannel = false
        let proceed = sub.withLock { () -> Bool in
            guard !sub.cancelled else { return false }
            isFirstOnChannel = retain(target.name)
            sub.channel = channel
            sub.channelName = target.name
            sub.messageListener = messageListener
            sub.channelStateListener = stateListener
            // If the channel attached before this point (e.g. shared instance
            // already up), its initial `attached` event was ignored (not yet
            // current), so seed the flag from live state; otherwise the upcoming
            // initial attach sets it. This makes the *next* `resumed == false`
            // count as a real continuity loss rather than a first attach.
            sub.reregistering = false
            sub.hasAttachedBefore = (channel.state == .attached)
            return true
        }
        guard proceed else {
            // Raced with teardown — undo the wiring we just created.
            if let messageListener { channel.unsubscribe(messageListener) }
            channel.off(stateListener)
            return
        }

        // Presence-based backends (e.g. GraphQL Pro) track live subscribers via
        // Ably presence (`presence.get` per trigger); a channel with no present
        // member is reaped and stops delivering. Enter presence once per channel,
        // balanced by a leave in `detachCurrentChannel`.
        if maintainsPresence, isFirstOnChannel {
            channel.presence.enter(nil) { _ in }
        }
    }

    /// Channel state callback. Terminates the stream on fatal failure; on a
    /// presence backend, triggers re-registration when the channel reattaches
    /// without continuity (`resumed == false`) after its first attach. Events
    /// from a channel we've already swapped away from (identity mismatch) or
    /// after teardown are ignored.
    private func handleChannelState(
        _ stateChange: ARTChannelStateChange,
        channel: ARTRealtimeChannel,
        sub: Subscription,
        context: WSContext,
        continuation: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation
    ) {
        let current = stateChange.current

        enum Action { case ignore, fail(String?), reregister }
        let action: Action = sub.withLock {
            // Events from a channel we've swapped away from, or after teardown,
            // are stale — ignore.
            guard !sub.cancelled, channel === sub.channel else { return .ignore }
            if current == .failed { return .fail(sub.channelName) }
            guard current == .attached else { return .ignore }

            let wasAttachedBefore = sub.hasAttachedBefore
            sub.hasAttachedBefore = true
            guard Self.shouldReregister(
                maintainsPresence: maintainsPresence,
                hasAttachedBefore: wasAttachedBefore,
                current: current,
                resumed: stateChange.resumed
            ), !sub.reregistering else { return .ignore }
            sub.reregistering = true
            return .reregister
        }

        switch action {
        case .ignore:
            return
        case .fail(let name):
            continuation.finish(throwing: Self.error(from: stateChange.reason, fallback: "Ably channel '\(name ?? "?")' failed"))
        case .reregister:
            let task = Task { [self] in
                await reregister(sub: sub, context: context, continuation: continuation)
            }
            let kept = sub.withLock { () -> Bool in
                guard !sub.cancelled else { return false }
                sub.reregisterTask = task
                return true
            }
            if !kept { task.cancel() }
        }
    }

    /// Re-establish a fresh subscription after continuity loss: drop the reaped
    /// channel, then register a new one (retrying transient registration
    /// failures with capped backoff) and attach it — all without breaking the
    /// consumer's stream. Detach-then-attach (rather than overlapping channels)
    /// avoids double-delivering frames into a non-idempotent consumer.
    private func reregister(
        sub: Subscription,
        context: WSContext,
        continuation: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation
    ) async {
        detachCurrentChannel(sub)

        var backoff = Self.reregisterInitialBackoff
        while !Task.isCancelled {
            if sub.withLock({ sub.cancelled }) { return }
            do {
                let target = try await resolveChannel(context)
                if Task.isCancelled { return }
                attachChannel(target, sub: sub, context: context, continuation: continuation)
                return
            } catch {
                // Transient registration failure (e.g. a flapping network right
                // after reconnect). Back off and retry; a fatal connection
                // `.failed` finishes the stream via the connection listener,
                // which tears us down. Stays silent — the consumer's stream is
                // uninterrupted and surfacing the error would end it.
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, Self.reregisterMaxBackoff)
            }
        }
    }

    private func makeChannel(_ target: AblyChannelTarget) -> ARTRealtimeChannel {
        guard let params = target.params else {
            return realtime.channels.get(target.name)
        }
        let options = ARTRealtimeChannelOptions()
        options.params = params
        return realtime.channels.get(target.name, options: options)
    }

    /// Tear down the subscription's current channel: remove listeners, leave
    /// presence, and release the channel once its last subscriber is gone.
    /// Idempotent — clears the box's channel refs so a second call (teardown
    /// racing a re-registration) is a no-op.
    private func detachCurrentChannel(_ sub: Subscription) {
        let (channel, name, messageListener, stateListener) = sub.withLock {
            defer {
                sub.channel = nil
                sub.channelName = nil
                sub.messageListener = nil
                sub.channelStateListener = nil
            }
            return (sub.channel, sub.channelName, sub.messageListener, sub.channelStateListener)
        }

        guard let channel else { return }
        if let messageListener { channel.unsubscribe(messageListener) }
        if let stateListener { channel.off(stateListener) }
        if let name, releaseRef(name) {
            // Last subscriber on this channel — leave presence (matches the enter
            // in `attachChannel`) so a presence-based server reaps the idle sub.
            if maintainsPresence { channel.presence.leave(nil) { _ in } }
            if releaseChannelWhenIdle { realtime.channels.release(name) }
        }
    }

    private func teardown(_ sub: Subscription) {
        let (setupTask, reregisterTask, connectionListener) = sub.withLock {
            sub.cancelled = true
            defer {
                sub.setupTask = nil
                sub.reregisterTask = nil
                sub.connectionListener = nil
            }
            return (sub.setupTask, sub.reregisterTask, sub.connectionListener)
        }

        setupTask?.cancel()
        reregisterTask?.cancel()
        if let connectionListener { realtime.connection.off(connectionListener) }
        detachCurrentChannel(sub)
    }

    /// Increments the ref-count; returns `true` when this is the first reference
    /// on the channel (so the caller enters Ably presence exactly once per channel).
    private func retain(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        channelRefCounts[name, default: 0] += 1
        return channelRefCounts[name] == 1
    }

    /// Decrements the ref-count; returns `true` when this was the last reference.
    private func releaseRef(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let remaining = (channelRefCounts[name] ?? 1) - 1
        if remaining <= 0 {
            channelRefCounts[name] = nil
            return true
        }
        channelRefCounts[name] = remaining
        return false
    }

    // MARK: - Reconnect decision (pure — unit-testable without Ably)

    /// Whether a channel state change is a continuity-loss reattach that, on a
    /// presence backend, requires re-registering the (now reaped) subscription.
    ///
    /// True only when: it's a presence backend, the channel has attached at
    /// least once before (so this isn't the initial attach, which is always
    /// `resumed == false`), the new state is `attached`, and continuity was lost
    /// (`resumed == false`). A `<2min` blip reattaches `resumed == true` with
    /// presence preserved server-side, so it's correctly excluded.
    static func shouldReregister(
        maintainsPresence: Bool,
        hasAttachedBefore: Bool,
        current: ARTRealtimeChannelState,
        resumed: Bool
    ) -> Bool {
        maintainsPresence && hasAttachedBefore && current == .attached && !resumed
    }

    // MARK: - Frame mapping (pure — unit-testable without Ably)

    /// Default `message.data` → `JSONValue` decode. Ably hands `data` back as
    /// `String`/`Data` (raw JSON) or already-decoded Foundation objects depending
    /// on how it was published; all three are handled.
    public static func defaultDecodeMessage(_ message: ARTMessage) -> JSONValue? {
        guard let data = message.data else { return nil }
        if let bytes = data as? Data { return try? JSONValue.from(json: bytes) }
        if let string = data as? String { return try? JSONValue.from(json: Data(string.utf8)) }
        return try? JSONValue.from(any: data)
    }

    /// Map a decoded payload to a result frame. A GraphQL envelope
    /// (`{data, errors}`) is split into `data` + `CombinedError`; any other
    /// payload is treated as the `data` itself.
    public static func result(from frame: JSONValue) -> OperationResult<JSONValue> {
        guard case .object(let object) = frame,
            object["data"] != nil || object["errors"] != nil
        else {
            return OperationResult(data: frame)
        }
        let data = object["data"] ?? .null
        var graphqlErrors: [GraphQLResponseError] = []
        if case .array(let items) = object["errors"] ?? .null {
            for item in items {
                if case .object(let entry) = item {
                    graphqlErrors.append(GraphQLResponseError(message: entry["message"]?.string ?? "GraphQL error"))
                }
            }
        }
        let error: CombinedError? = graphqlErrors.isEmpty ? nil : CombinedError(graphqlErrors: graphqlErrors)
        if case .null = data {
            return OperationResult(data: nil, error: error)
        }
        return OperationResult(data: data, error: error)
    }

    // MARK: - Errors

    private static func error(from reason: ARTErrorInfo?, fallback: String) -> CombinedError {
        CombinedError(networkMessage: reason?.message ?? fallback)
    }

    private static func error(from error: Error, fallback: String) -> CombinedError {
        if let combined = error as? CombinedError { return combined }
        if let info = error as? ARTErrorInfo { return CombinedError(networkMessage: info.message) }
        return CombinedError(networkError: error)
    }

    // MARK: - Per-subscription state

    /// Shared between the setup `Task`, the Ably listener callbacks, the
    /// re-registration `Task`, and `onTermination`. Holds Ably handles (not
    /// `Sendable`); every field is guarded by `lock` because, unlike the
    /// original one-shot setup, these actors now run concurrently (a channel
    /// callback can fire a re-registration while teardown races it).
    private final class Subscription: @unchecked Sendable {
        private let lock = NSLock()

        /// Scoped locking. A plain `lock()`/`unlock()` pair is unavailable from
        /// async contexts under strict concurrency (it can block the cooperative
        /// pool); this sync wrapper is callable from both the Ably callbacks and
        /// the async re-registration task. The body must not suspend.
        func withLock<R>(_ body: () -> R) -> R {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        var channel: ARTRealtimeChannel?
        var channelName: String?
        var messageListener: ARTEventListener?
        var channelStateListener: ARTEventListener?
        var connectionListener: ARTEventListener?
        var setupTask: Task<Void, Never>?
        var reregisterTask: Task<Void, Never>?
        /// Set on the current channel's first `attached`; distinguishes the
        /// initial attach (always `resumed == false`) from a later reattach.
        var hasAttachedBefore = false
        /// A re-registration is in flight — drops duplicate continuity-loss
        /// triggers until the fresh channel is attached.
        var reregistering = false
        /// The consumer dropped the stream — stop establishing new channels.
        var cancelled = false
    }
}

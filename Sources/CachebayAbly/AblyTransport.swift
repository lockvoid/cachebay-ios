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
        self.init(realtime: realtime, ownsRealtime: false,
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
        self.init(realtime: ARTRealtime(options: options), ownsRealtime: true,
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

                    let channel = makeChannel(target)
                    sub.channel = channel
                    sub.channelName = target.name
                    let isFirstOnChannel = retain(target.name)

                    // Fatal connection failure → terminate this stream. Transient
                    // disconnect/suspend are left alone (Ably auto-recovers).
                    sub.connectionListener = realtime.connection.on { stateChange in
                        guard stateChange.current == .failed else { return }
                        continuation.finish(throwing: Self.error(from: stateChange.reason, fallback: "Ably connection failed"))
                    }

                    // Fatal channel failure (e.g. denied capability) → terminate.
                    sub.channelStateListener = channel.on { stateChange in
                        guard stateChange.current == .failed else { return }
                        continuation.finish(throwing: Self.error(from: stateChange.reason, fallback: "Ably channel '\(target.name)' failed"))
                    }

                    let onMessage: (ARTMessage) -> Void = { message in
                        guard let frame = self.decodeMessage(message) else { return }
                        continuation.yield(Self.result(from: frame))
                    }
                    if let eventName = target.eventName {
                        sub.messageListener = channel.subscribe(eventName, callback: onMessage)
                    } else {
                        sub.messageListener = channel.subscribe(onMessage)
                    }

                    // Presence-based backends (e.g. GraphQL Pro) track live
                    // subscribers via Ably presence (`still_subscribed?` →
                    // `presence.get`); a channel with no present member is reaped
                    // and stops delivering. When opted in, enter presence so the
                    // server keeps the subscription alive — once per channel,
                    // balanced by a leave in `teardown`.
                    if maintainsPresence, isFirstOnChannel {
                        channel.presence.enter(nil) { _ in }
                    }
                } catch {
                    continuation.finish(throwing: Self.error(from: error, fallback: "Ably subscribe failed"))
                }
            }
            sub.setupTask = setup

            continuation.onTermination = { [self] _ in
                setup.cancel()
                teardown(sub)
            }
        }
    }

    // MARK: - Channel plumbing

    private func makeChannel(_ target: AblyChannelTarget) -> ARTRealtimeChannel {
        guard let params = target.params else {
            return realtime.channels.get(target.name)
        }
        let options = ARTRealtimeChannelOptions()
        options.params = params
        return realtime.channels.get(target.name, options: options)
    }

    private func teardown(_ sub: Subscription) {
        if let channel = sub.channel {
            if let listener = sub.messageListener { channel.unsubscribe(listener) }
            if let listener = sub.channelStateListener { channel.off(listener) }
        }
        if let listener = sub.connectionListener { realtime.connection.off(listener) }
        if let name = sub.channelName, releaseRef(name) {
            // Last subscriber on this channel — leave presence (matches the enter
            // in `subscribe`) so a presence-based server reaps the idle sub.
            if maintainsPresence { sub.channel?.presence.leave(nil) { _ in } }
            if releaseChannelWhenIdle { realtime.channels.release(name) }
        }
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
              object["data"] != nil || object["errors"] != nil else {
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

    /// Shared between the setup `Task` and `onTermination`. Holds Ably handles
    /// (not `Sendable`); access is serial in practice (setup runs once, teardown
    /// once after), so `@unchecked` is sound.
    private final class Subscription: @unchecked Sendable {
        var channel: ARTRealtimeChannel?
        var channelName: String?
        var messageListener: ARTEventListener?
        var channelStateListener: ARTEventListener?
        var connectionListener: ARTEventListener?
        var setupTask: Task<Void, Never>?
    }
}

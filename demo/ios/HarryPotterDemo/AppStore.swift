import Foundation
import Cachebay

/// Owns the `CachebayClient` for the whole app. Wired with URLSession HTTP +
/// graphql-transport-ws WebSocket + a SQLite replica under the app's Caches dir.
@MainActor
final class AppStore: ObservableObject {
    let client: CachebayClient

    init() {
        let base = URL(string: "http://127.0.0.1:4000/graphql")!
        let ws   = URL(string: "ws://127.0.0.1:4000/graphql")!

        let dbPath = Self.cachesDir().appendingPathComponent("cachebay.sqlite").path

        let http = URLSessionHTTPTransport(url: base)
        let wsTransport = URLSessionWebSocketTransport(url: ws)

        self.client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: http, ws: wsTransport),
            cachePolicy: .cacheAndNetwork,
            suspensionTimeout: 0.5,
            storage: SQLiteStorage.factory(options: .init(path: dbPath))
        ))
    }

    private static func cachesDir() -> URL {
        let fm = FileManager.default
        let url = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return url
    }
}

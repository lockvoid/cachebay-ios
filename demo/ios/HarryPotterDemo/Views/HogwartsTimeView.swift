import SwiftUI
import Cachebay

/// Live subscription ticker. Demos the WebSocket transport round-trip.
struct HogwartsTimeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var time: String = "—"
    @State private var subscriptionTask: Task<Void, Never>? = nil

    var body: some View {
        Label(formattedTime, systemImage: "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
            .task {
                subscribe()
            }
            .onDisappear {
                subscriptionTask?.cancel()
                subscriptionTask = nil
            }
    }

    private var formattedTime: String {
        guard let iso = ISO8601DateFormatter().date(from: time) else { return time }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: iso)
    }

    private func subscribe() {
        subscriptionTask?.cancel()
        let client = store.client
        subscriptionTask = Task { @Sendable in
            do {
                let stream = try client.executeSubscription(HogwartsTime.self, variables: .init())
                for try await event in stream {
                    if Task.isCancelled { break }
                    if let t = event.data?.hogwartsTimeUpdated.time {
                        await MainActor.run { time = t }
                    }
                }
            } catch { /* best-effort clock; server may be down */ }
        }
    }
}

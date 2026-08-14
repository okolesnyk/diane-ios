import DianeKit
import Foundation
import Observation

/// Fan-out point for the SSE stream: screens key their `.task(id:)` on
/// `version(of:)` so a server-side change (or a reconnect, when anything may
/// have been missed) triggers a refetch — the same invalidate-on-event model
/// the web kiosk uses.
@MainActor
@Observable
final class SyncSignals {
    /// Bumped on every (re)established stream connection.
    private(set) var epoch = 0
    private(set) var counters: [DianeTopic: Int] = [:]

    func apply(_ signal: SSESignal) {
        switch signal {
        case .connected:
            epoch += 1
        case .event(let event):
            guard let topic = DianeTopic(rawValue: event.name) else { return }
            counters[topic, default: 0] += 1
        case .unauthorized:
            break  // terminal; RootTabView routes it to AppState
        }
    }

    /// Monotonic per-view refetch key: changes when any of `topics` changes
    /// or the stream reconnects.
    func version(of topics: Set<DianeTopic>) -> Int {
        epoch * 1_000_000 + topics.reduce(0) { $0 + (counters[$1] ?? 0) }
    }

    /// A locally-sourced change (offline replay drained) — same refetch
    /// path as a server event, no stream round-trip needed.
    func bumpLocal(_ topic: DianeTopic) {
        counters[topic, default: 0] += 1
    }
}

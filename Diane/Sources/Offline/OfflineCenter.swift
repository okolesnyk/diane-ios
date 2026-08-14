import DianeKit
import SwiftUI

/// Main-actor mirror of the OfflineController for the UI: the pill reads it,
/// RootTabView wires its drain signal into SyncSignals so open views refetch
/// after a replay lands.
@MainActor
@Observable
final class OfflineCenter {
    private(set) var offline = false
    private(set) var lastSync: Date?
    private(set) var pending = 0
    /// Wired by RootTabView to bump the lists topic after a replay drains.
    var onDrained: (() -> Void)?

    let controller: OfflineController

    init(controller: OfflineController) {
        self.controller = controller
        Task {
            await controller.configure(
                onChange: { snapshot in
                    Task { @MainActor in self.apply(snapshot) }
                },
                onDrained: {
                    Task { @MainActor in self.onDrained?() }
                }
            )
        }
    }

    private func apply(_ snapshot: OfflineSnapshot) {
        offline = snapshot.offline
        lastSync = snapshot.lastSync
        pending = snapshot.pending
    }

    func kickReplay() {
        Task { await controller.kickReplay() }
    }

    func clear() {
        Task { await controller.clear() }
    }
}

/// The quiet offline pill: shows only when offline or changes are waiting,
/// never error chrome — cached content below it stays fully usable.
struct OfflinePill: View {
    let center: OfflineCenter

    var body: some View {
        if center.offline || center.pending > 0 {
            HStack(spacing: 5) {
                Image(systemName: center.offline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.fill.secondary, in: Capsule())
            .padding(.vertical, 4)
            .transition(.opacity)
        }
    }

    private var label: String {
        var parts: [String] = []
        if center.offline {
            if let lastSync = center.lastSync {
                let ago = RelativeDateTimeFormatter().localizedString(for: lastSync, relativeTo: Date())
                parts.append("Offline \u{00B7} last sync \(ago)")
            } else {
                parts.append("Offline")
            }
        }
        if center.pending > 0 {
            parts.append("\(center.pending) waiting")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

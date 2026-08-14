import CryptoKit
import Foundation

/// Flat-file snapshot store: the raw JSON of cached GETs plus the outbox and
/// the last successful-sync stamp. A cache, not a database — files are the
/// exact wire payloads, so there is no mapping layer and no migrations.
/// Single-threaded by contract: only OfflineController touches it.
final class OfflineStore {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Per-origin store under Application Support so cached households never
    /// mix across servers.
    static func directory(for origin: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let host = "\(origin.host ?? "server")-\(origin.port ?? 0)"
        return support.appending(path: "OfflineCache/\(host)")
    }

    // MARK: - Snapshots

    private func snapshotURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "snap-\(digest).json")
    }

    func snapshot(_ key: String) -> Data? {
        try? Data(contentsOf: snapshotURL(key))
    }

    func writeSnapshot(_ key: String, _ data: Data) {
        try? data.write(to: snapshotURL(key), options: .atomic)
    }

    // MARK: - Outbox

    private var outboxURL: URL { directory.appending(path: "outbox.json") }

    func loadOutbox() -> [QueuedOp] {
        guard let data = try? Data(contentsOf: outboxURL) else { return [] }
        return (try? JSONDecoder().decode([QueuedOp].self, from: data)) ?? []
    }

    func saveOutbox(_ ops: [QueuedOp]) {
        guard let data = try? JSONEncoder().encode(ops) else { return }
        try? data.write(to: outboxURL, options: .atomic)
    }

    // MARK: - Last sync

    private var lastSyncURL: URL { directory.appending(path: "last-sync") }

    func loadLastSync() -> Date? {
        guard let raw = try? String(contentsOf: lastSyncURL, encoding: .utf8),
              let interval = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    func saveLastSync(_ date: Date) {
        try? String(date.timeIntervalSince1970).write(to: lastSyncURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

import Foundation
import HTTPTypes

/// The offline brain: snapshot cache, outbox, and replay. CacheMiddleware
/// feeds it request outcomes; the app observes it through `onChange` and
/// pokes `kickReplay()` on foreground/reachability nudges.
public actor OfflineController {
    private let store: OfflineStore
    private let origin: URL
    private let token: @Sendable () -> String?
    private let session: URLSession

    private var ops: [QueuedOp]
    private var offline = false
    private var lastSync: Date?
    private var replaying = false

    /// Pushed on every state change (hop to the main actor yourself).
    public var onChange: (@Sendable (OfflineSnapshot) -> Void)?
    /// Fired after a replay drained at least one op — refetch time.
    public var onDrained: (@Sendable () -> Void)?

    public init(origin: URL, token: @escaping @Sendable () -> String?) {
        self.origin = origin
        self.token = token
        self.session = URLSession(configuration: .ephemeral)
        let store = OfflineStore(directory: OfflineStore.directory(for: origin))
        self.store = store
        self.ops = store.loadOutbox()
        self.lastSync = store.loadLastSync()
    }

    public func configure(
        onChange: @escaping @Sendable (OfflineSnapshot) -> Void,
        onDrained: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.onDrained = onDrained
        notify()
    }

    public func snapshot() -> OfflineSnapshot {
        OfflineSnapshot(offline: offline, lastSync: lastSync, pending: ops.count)
    }

    // MARK: - Middleware feed

    func cached(_ key: String) -> Data? { store.snapshot(key) }

    func storeResponse(_ key: String, _ data: Data) {
        store.writeSnapshot(key, data)
    }

    func noteSuccess() {
        lastSync = Date()
        store.saveLastSync(lastSync!)
        if offline {
            offline = false
            notify()
        }
        if !ops.isEmpty { kickReplay() }
    }

    func noteNetworkFailure() {
        guard !offline else { return }
        offline = true
        notify()
    }

    /// The queueable Lists mutations, by generated operation id.
    static let queueable: Set<String> = [
        "addListItem", "updateListItem", "deleteListItem", "orderListItems",
    ]

    /// Queue a Lists mutation that failed on the network: apply it to the
    /// cached payloads (so reloading views see the optimistic result) and
    /// remember the raw request for replay. Returns false when the op can't
    /// be applied (no cache to patch) — the caller then rethrows.
    func queueListsOp(operationID: String, method: String, path: String, body: Data?) -> Bool {
        guard Self.queueable.contains(operationID) else { return false }
        let parts = path.split(separator: "/").map(String.init)
        // …/lists/{id}/items[…]
        guard let listsAt = parts.firstIndex(of: "lists"), parts.count > listsAt + 1 else { return false }
        let listId = parts[listsAt + 1]
        let detailKey = "/api/v1/lists/\(listId)"
        guard let detail = store.snapshot(detailKey) else { return false }

        let applied: OfflineLists.Applied?
        var summary = "Update list"
        var tempId: String?
        switch operationID {
        case "addListItem":
            guard let body else { return false }
            applied = OfflineLists.applyAdd(
                detail: detail,
                body: body,
                library: store.snapshot("/api/v1/grocery/library"),
                categories: store.snapshot("/api/v1/grocery/categories")
            )
            tempId = applied?.createdItemId
            if let add = try? JSONDecoder().decode(OfflineLists.AddBody.self, from: body) {
                summary = "Add \(add.name)"
            }
        case "updateListItem", "deleteListItem":
            guard parts.count > listsAt + 3 else { return false }
            let itemId = parts[listsAt + 3]
            if operationID == "deleteListItem" {
                applied = OfflineLists.applyDelete(detail: detail, itemId: itemId)
                summary = "Delete item"
            } else {
                guard let body else { return false }
                applied = OfflineLists.applyUpdate(detail: detail, itemId: itemId, body: body)
                summary = "Update item"
            }
        case "orderListItems":
            guard let body else { return false }
            applied = OfflineLists.applyOrder(detail: detail, body: body)
            summary = "Reorder items"
        default:
            return false
        }
        guard let applied else { return false }

        store.writeSnapshot(detailKey, applied.detail)
        if applied.itemDelta != 0 || applied.checkedDelta != 0,
           let index = store.snapshot("/api/v1/lists"),
           let patched = OfflineLists.patchIndexCounts(
               index: index, listId: listId,
               itemDelta: applied.itemDelta, checkedDelta: applied.checkedDelta
           ) {
            store.writeSnapshot("/api/v1/lists", patched)
        }

        ops.append(QueuedOp(method: method, path: path, body: body, summary: summary, tempId: tempId))
        store.saveOutbox(ops)
        noteNetworkFailure()
        notify()
        return true
    }

    // MARK: - Replay

    public func kickReplay() {
        guard !replaying, !ops.isEmpty else { return }
        replaying = true
        Task { await self.replay() }
    }

    private func replay() async {
        defer { replaying = false }
        var drained = 0
        while let op = ops.first {
            guard var url = URL(string: op.path, relativeTo: origin) else { drop(); drained += 1; continue }
            url = url.absoluteURL
            var request = URLRequest(url: url)
            request.httpMethod = op.method
            request.httpBody = op.body
            if op.body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let token = token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

            let data: Data
            let status: Int
            do {
                let (body, response) = try await session.data(for: request)
                data = body
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                noteNetworkFailure()
                break
            }

            switch status {
            case 200..<300:
                if let temp = op.tempId,
                   let created = try? JSONDecoder().decode(CreatedItem.self, from: data) {
                    drop()
                    ops = OfflineLists.rewriteTempId(ops, temp: temp, real: created.id)
                    store.saveOutbox(ops)
                } else {
                    drop()
                }
                drained += 1
                lastSync = Date()
                store.saveLastSync(lastSync!)
                offline = false
            case 401, 500..<600:
                // Dead token or a server hiccup: hold the queue and retry
                // later — dropping here would lose real work.
                notify()
                return
            default:
                // A semantic 4xx: the server ruled (deleted meanwhile,
                // validation). Drop and keep going — never wedge the queue.
                drop()
                drained += 1
            }
            notify()
        }
        notify()
        if drained > 0, ops.isEmpty { onDrained?() }
    }

    private struct CreatedItem: Codable { var id: String }

    private func drop() {
        guard !ops.isEmpty else { return }
        ops.removeFirst()
        store.saveOutbox(ops)
    }

    // MARK: - Lifecycle

    public func clear() {
        ops = []
        offline = false
        lastSync = nil
        store.clear()
        notify()
    }

    private func notify() {
        onChange?(snapshot())
    }
}

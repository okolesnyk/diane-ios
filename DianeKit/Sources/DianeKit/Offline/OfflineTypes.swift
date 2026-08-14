import Foundation

/// One queued offline mutation: the raw request, replayed verbatim (with
/// temp-id rewrites) once the server is reachable again.
public struct QueuedOp: Codable, Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var method: String
    public var path: String
    public var body: Data?
    /// Human line for a pending-changes display ("Add Milk").
    public var summary: String
    /// Set when this op created a local item: its temp id, swapped for the
    /// server's id (across all later ops) when the create replays.
    public var tempId: String?

    public init(method: String, path: String, body: Data?, summary: String, tempId: String? = nil) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.method = method
        self.path = path
        self.body = body
        self.summary = summary
        self.tempId = tempId
    }
}

/// What the UI needs to know, pushed on every state change.
public struct OfflineSnapshot: Sendable, Equatable {
    public var offline: Bool
    public var lastSync: Date?
    public var pending: Int

    public init(offline: Bool = false, lastSync: Date? = nil, pending: Int = 0) {
        self.offline = offline
        self.lastSync = lastSync
        self.pending = pending
    }
}

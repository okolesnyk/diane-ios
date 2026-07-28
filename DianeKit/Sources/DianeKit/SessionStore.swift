import Foundation

/// The persisted result of a successful member sign-in. The iOS app is the
/// family-member remote: member sessions only — family/kiosk and service
/// sessions stay on the web kiosk.
public struct StoredSession: Codable, Sendable, Equatable {
    public var serverURL: URL
    public var token: String
    public var memberID: String
    public var memberName: String
    public var memberColor: String
    public var memberRole: String

    public init(
        serverURL: URL,
        token: String,
        memberID: String,
        memberName: String,
        memberColor: String,
        memberRole: String
    ) {
        self.serverURL = serverURL
        self.token = token
        self.memberID = memberID
        self.memberName = memberName
        self.memberColor = memberColor
        self.memberRole = memberRole
    }

    /// mom/dad are admins (server-enforced; this only gates what the UI offers).
    public var isAdmin: Bool { memberRole == "mom" || memberRole == "dad" }
}

/// JSON-over-persistence session storage. A corrupt payload reads as
/// signed-out, never a crash.
public struct SessionStore: Sendable {
    let persistence: SessionPersistence

    public init(persistence: SessionPersistence = KeychainSessionPersistence()) {
        self.persistence = persistence
    }

    public func load() -> StoredSession? {
        guard let data = persistence.read() else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) {
        persistence.write(try? JSONEncoder().encode(session))
    }

    public func clear() {
        persistence.write(nil)
    }
}

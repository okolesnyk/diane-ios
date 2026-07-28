import Foundation
import Testing

@testable import DianeKit

@Suite("session store")
struct SessionStoreTests {
    private func makeSession() -> StoredSession {
        StoredSession(
            serverURL: URL(string: "https://family.example.com")!,
            token: "tok-123",
            memberID: "m1",
            memberName: "Ada",
            memberColor: "#e5484d",
            memberRole: "kid"
        )
    }

    @Test("round-trips through persistence")
    func roundTrip() {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        #expect(store.load() == nil)
        let session = makeSession()
        store.save(session)
        #expect(store.load() == session)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("corrupt payload reads as signed out")
    func corrupt() {
        let persistence = InMemorySessionPersistence()
        persistence.write(Data("not json".utf8))
        #expect(SessionStore(persistence: persistence).load() == nil)
    }

    @Test("mom and dad are admins, kids are not")
    func adminRoles() {
        var session = makeSession()
        #expect(!session.isAdmin)
        session.memberRole = "mom"
        #expect(session.isAdmin)
        session.memberRole = "dad"
        #expect(session.isAdmin)
    }
}

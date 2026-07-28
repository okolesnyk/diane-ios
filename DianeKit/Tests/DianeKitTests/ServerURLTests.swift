import Foundation
import Testing

@testable import DianeKit

@Suite("server URL normalization")
struct ServerURLTests {
    @Test("bare domain defaults to https")
    func bareDomain() {
        #expect(ServerURL.normalize("family.example.com")?.absoluteString == "https://family.example.com")
    }

    @Test("LAN-style hosts default to http")
    func lanHosts() {
        #expect(ServerURL.normalize("192.168.1.20:3000")?.absoluteString == "http://192.168.1.20:3000")
        #expect(ServerURL.normalize("localhost:3100")?.absoluteString == "http://localhost:3100")
        #expect(ServerURL.normalize("diane.local")?.absoluteString == "http://diane.local")
    }

    // ATS refuses plain http to qualified names like *.lan — defaulting them
    // to http would promise a connection the OS blocks (review M9).
    @Test("qualified .lan names stay https")
    func lanTld() {
        #expect(ServerURL.normalize("box.lan:8080")?.absoluteString == "https://box.lan:8080")
    }

    @Test("explicit scheme wins")
    func explicitScheme() {
        #expect(ServerURL.normalize("https://192.168.1.20")?.absoluteString == "https://192.168.1.20")
        #expect(ServerURL.normalize("http://family.example.com")?.absoluteString == "http://family.example.com")
    }

    @Test("pasted deep links reduce to the origin")
    func stripsPathQueryFragment() {
        let url = ServerURL.normalize("https://family.example.com/chores?x=1#frag")
        #expect(url?.absoluteString == "https://family.example.com")
    }

    @Test("credentials in the URL are dropped")
    func stripsUserInfo() {
        #expect(ServerURL.normalize("https://user:pw@family.example.com")?.absoluteString == "https://family.example.com")
    }

    @Test("whitespace is trimmed")
    func trims() {
        #expect(ServerURL.normalize("  family.example.com\n")?.absoluteString == "https://family.example.com")
    }

    @Test("garbage is rejected")
    func rejects() {
        #expect(ServerURL.normalize("") == nil)
        #expect(ServerURL.normalize("   ") == nil)
        #expect(ServerURL.normalize("ftp://x.example") == nil)
        #expect(ServerURL.normalize("not a url") == nil)
        #expect(ServerURL.normalize("/") == nil)
        #expect(ServerURL.normalize("https://") == nil)
    }

    @Test("non-quad dotted names stay https")
    func dottedNames() {
        #expect(ServerURL.normalize("10.0.0")?.absoluteString == "https://10.0.0")
        #expect(ServerURL.normalize("300.1.2.3")?.absoluteString == "https://300.1.2.3")
    }
}

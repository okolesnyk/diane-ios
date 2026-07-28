import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import DianeKit

/// Records what the generated client actually sends and answers with a
/// canned identities payload so the call completes.
struct RecordingTransport: ClientTransport {
    let record: @Sendable (HTTPRequest, URL) -> Void

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        record(request, baseURL)
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let json = #"{"configured":true,"householdName":"T","restricted":false,"members":[]}"#
        return (response, HTTPBody(json))
    }
}

@Suite("DianeClient wiring")
struct DianeClientTests {
    // The spec's paths already include /api/v1 — the serverURL must be the
    // bare origin or every request becomes /api/v1/api/v1/... and 404s.
    // Caught live in M9; never again.
    @Test("no doubled /api/v1 prefix")
    func pathPrefix() async throws {
        let recorded = Recorder()
        let client = DianeClient(
            origin: URL(string: "http://localhost:3100")!,
            token: { nil },
            transport: RecordingTransport { request, baseURL in
                recorded.set(path: request.path, base: baseURL.absoluteString)
            }
        )
        _ = try await client.api.listIdentities()
        #expect(recorded.base == "http://localhost:3100")
        #expect(recorded.path == "/api/v1/auth/identities")
    }

    @Test("bearer token injected when present, absent when nil")
    func authHeader() async throws {
        let recorded = Recorder()
        let transport = RecordingTransport { request, _ in
            recorded.set(path: request.headerFields[.authorization], base: "")
        }
        _ = try await DianeClient(
            origin: URL(string: "https://x.example")!,
            token: { "tok-1" },
            transport: transport
        ).api.listIdentities()
        #expect(recorded.path == "Bearer tok-1")

        _ = try await DianeClient(
            origin: URL(string: "https://x.example")!,
            token: { nil },
            transport: transport
        ).api.listIdentities()
        #expect(recorded.path == nil)
    }
}

/// Tiny thread-safe capture box for the @Sendable transport closure.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String?
    private var _base: String?

    func set(path: String?, base: String?) {
        lock.withLock {
            _path = path
            _base = base
        }
    }

    var path: String? { lock.withLock { _path } }
    var base: String? { lock.withLock { _base } }
}

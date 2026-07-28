import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// The one place the app builds an API client. `api` is the generated
/// operations surface (Client from openapi.yaml); everything session-scoped
/// hangs off the origin the user signed in to.
///
/// The spec's paths already carry the /api/v1 prefix, so the client's
/// serverURL is the bare origin — appending /api/v1 here doubles the prefix
/// and 404s every call (regression-pinned in DianeClientTests).
public struct DianeClient: Sendable {
    public let api: Client
    public let origin: URL

    public init(
        origin: URL,
        token: @escaping @Sendable () -> String?,
        transport: any ClientTransport = URLSessionTransport()
    ) {
        self.origin = origin
        self.api = Client(
            serverURL: origin,
            transport: transport,
            middlewares: [BearerAuthMiddleware(token: token)]
        )
    }

    /// SSE endpoint — consumed by SSEClient, not the generated client.
    public var streamURL: URL { origin.appending(path: "api/v1/stream") }
}

/// Injects `Authorization: Bearer <token>` on every request. The token
/// closure reads current state so a re-login never rebuilds the client.
struct BearerAuthMiddleware: ClientMiddleware {
    let token: @Sendable () -> String?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = token() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}

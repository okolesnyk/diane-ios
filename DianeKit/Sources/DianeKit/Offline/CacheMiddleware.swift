import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Offline-first at the transport seam, so views need no offline code:
/// - every successful GET writes through to the snapshot store;
/// - a GET that fails on the network serves the cached copy instead;
/// - an allowlisted Lists mutation that fails on the network is queued to
///   the outbox (the controller patches the cache optimistically) and
///   answered with a synthetic 204 — the calling view reloads and sees the
///   optimistic state through its normal path.
struct CacheMiddleware: ClientMiddleware {
    let controller: OfflineController

    private static let bodyLimit = 4 * 1024 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        let isGet = request.method == .get
        let queueable = OfflineController.queueable.contains(operationID)

        // Mutations we may need to queue must have their body buffered so it
        // can be sent now AND stored on failure.
        var bufferedRequestBody: Data?
        var outgoing = body
        if queueable, let body {
            let data = try await Data(collecting: body, upTo: Self.bodyLimit)
            bufferedRequestBody = data
            outgoing = HTTPBody(data)
        }

        do {
            let (response, responseBody) = try await next(request, outgoing, baseURL)
            if isGet, response.status == .ok, let responseBody {
                let data = try await Data(collecting: responseBody, upTo: Self.bodyLimit)
                await controller.storeResponse(path, data)
                await controller.noteSuccess()
                return (response, HTTPBody(data))
            }
            if response.status.code < 500 { await controller.noteSuccess() }
            return (response, responseBody)
        } catch {
            guard isNetworkError(error) else { throw error }
            if isGet, let cached = await controller.cached(path) {
                await controller.noteNetworkFailure()
                var response = HTTPResponse(status: .ok)
                response.headerFields[.contentType] = "application/json"
                return (response, HTTPBody(cached))
            }
            if queueable,
               await controller.queueListsOp(
                   operationID: operationID,
                   method: request.method.rawValue,
                   path: path,
                   body: bufferedRequestBody
               ) {
                return (HTTPResponse(status: .noContent), nil)
            }
            await controller.noteNetworkFailure()
            throw error
        }
    }

    private func isNetworkError(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if let clientError = error as? ClientError {
            return clientError.underlyingError is URLError
        }
        return false
    }
}

import Foundation

/// One parsed SSE event from /api/v1/stream.
public struct SSEvent: Sendable, Equatable {
    public var name: String
    public var data: String

    public init(name: String, data: String) {
        self.name = name
        self.data = data
    }
}

/// What consumers see: `.connected` fires after every (re)established stream —
/// the signal to refetch, since anything may have changed while disconnected
/// (iOS suspends the socket whenever the app leaves the foreground).
/// `.unauthorized` is TERMINAL: the token was rejected (revoked session) —
/// retrying it forever would hide the sign-out from the user (review M9).
public enum SSESignal: Sendable, Equatable {
    case connected
    case event(SSEvent)
    case unauthorized
}

/// The change topics Diane's api publishes.
public enum DianeTopic: String, CaseIterable, Sendable {
    case events = "events-changed"
    case calendars = "calendars-changed"
    case members = "members-changed"
    case stars = "stars-changed"
    case rewards = "rewards-changed"
    case lists = "lists-changed"
    case chores = "chores-changed"
    case routines = "routines-changed"
    case settings = "settings-changed"
}

/// Incremental SSE field parser (WHATWG rules, the subset Diane emits):
/// dispatch on blank line, `:` comment/heartbeat lines dropped, multi-line
/// data joined with \n. Pure so tests can drive it line by line.
public struct SSEParser: Sendable {
    var eventName = ""
    var dataLines: [String] = []

    public init() {}

    public mutating func feed(line: String) -> SSEvent? {
        if line.isEmpty {
            defer {
                eventName = ""
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return SSEvent(
                name: eventName.isEmpty ? "message" : eventName,
                data: dataLines.joined(separator: "\n")
            )
        }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break  // id/retry unused by Diane
        }
        return nil
    }
}

/// Byte-to-line chunking for the stream (handles \n and \r\n). Separate from
/// the parser so both stay pure and testable.
struct LineBuffer {
    private var bytes: [UInt8] = []

    mutating func feed(_ byte: UInt8) -> String? {
        guard byte == UInt8(ascii: "\n") else {
            bytes.append(byte)
            return nil
        }
        if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
        defer { bytes = [] }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Long-lived subscription to /api/v1/stream with automatic reconnect
/// (exponential backoff 1s→30s, reset after a successful connect). Ends only
/// when the consuming task is cancelled — sign-out and scene-phase handling
/// live in the app layer.
public struct SSEClient: Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        // Idle timeout between chunks; the server heartbeats every 30s, so 90s
        // only trips when the connection is genuinely dead.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config)
    }

    public func signals(
        url: URL,
        token: @escaping @Sendable () -> String?
    ) -> AsyncStream<SSESignal> {
        let session = self.session
        return AsyncStream { continuation in
            let task = Task {
                var delay: Double = 1
                connect: while !Task.isCancelled {
                    do {
                        var request = URLRequest(url: url)
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                        if let token = token() {
                            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        }
                        let (bytes, response) = try await session.bytes(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 || status == 403 {
                            continuation.yield(.unauthorized)
                            break connect
                        }
                        guard status == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        continuation.yield(.connected)
                        delay = 1
                        var lineBuffer = LineBuffer()
                        var parser = SSEParser()
                        for try await byte in bytes {
                            if let line = lineBuffer.feed(byte),
                               let event = parser.feed(line: line) {
                                continuation.yield(.event(event))
                            }
                        }
                    } catch {
                        // Fall through to backoff; cancellation exits below.
                    }
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

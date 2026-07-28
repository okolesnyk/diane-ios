import Foundation

/// Turns what a family member types into the sign-in field ("family.example.com",
/// "192.168.1.20:3000/") into an origin URL. Scheme-less input defaults to
/// https, except hosts ATS actually allows plain http for (raw IPv4,
/// localhost, *.local via NSAllowsLocalNetworking). Qualified names like
/// *.lan deliberately stay https: defaulting them to http would promise a
/// connection ATS refuses at the socket layer (review M9).
public enum ServerURL {
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            let host = text.split(separator: "/", maxSplits: 1).first?
                .split(separator: ":", maxSplits: 1).first
                .map { $0.lowercased() } ?? ""
            text = (isLocalHost(host) ? "http://" : "https://") + text
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        // Origin only: a pasted deep link must not poison every request path.
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

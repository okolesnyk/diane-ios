import Foundation
import Security

/// Where the signed-in session lives between launches. A protocol so tests
/// never touch the real Keychain (host `swift test` has no entitlements).
public protocol SessionPersistence: Sendable {
    func read() -> Data?
    func write(_ data: Data?)
}

/// Generic-password Keychain item. `AfterFirstUnlock` so the session (and
/// with it push re-registration) survives a locked-device relaunch;
/// `ThisDeviceOnly` so it never migrates via device backups — restoring a
/// parent's backup onto a kid's phone must not clone the parent's admin
/// session (review M9). App-uninstall survival is handled by the fresh-
/// install purge in AppState.
public struct KeychainSessionPersistence: SessionPersistence {
    let service: String
    let account: String

    public init(service: String = "dev.stilltesting.diane", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ data: Data?) {
        guard let data else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query.merge(attributes) { _, new in new }
            SecItemAdd(query as CFDictionary, nil)
        }
    }
}

/// In-memory stand-in for tests and previews.
public final class InMemorySessionPersistence: SessionPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    public init() {}

    public func read() -> Data? {
        lock.withLock { stored }
    }

    public func write(_ data: Data?) {
        lock.withLock { stored = data }
    }
}

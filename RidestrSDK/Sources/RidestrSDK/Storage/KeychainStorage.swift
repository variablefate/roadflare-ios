import Foundation
import Security

/// Protocol for Keychain operations. Abstracted for testability.
public protocol KeychainStorageProtocol: Sendable {
    func save(data: Data, for key: String) throws
    func load(for key: String) throws -> Data?
    func delete(for key: String) throws
    func exists(for key: String) throws -> Bool
}

/// Keychain-backed secure storage using Security framework.
public final class KeychainStorage: KeychainStorageProtocol, Sendable {
    private let service: String
    private let accessGroup: String?

    /// - Parameters:
    ///   - service: The Keychain service identifier (e.g., "com.roadflare.keys").
    ///   - accessGroup: Optional Keychain access group for shared access.
    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(data: Data, for key: String) throws {
        // Delete existing item first (upsert pattern)
        try? delete(for: key)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RidestrError.keychainError(status)
        }
    }

    public func load(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw RidestrError.keychainError(status)
        }
    }

    public func delete(for key: String) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RidestrError.keychainError(status)
        }
    }

    public func exists(for key: String) throws -> Bool {
        let data = try load(for: key)
        return data != nil
    }

    // MARK: - Private

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

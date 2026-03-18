import Foundation
@testable import RidestrSDK

/// In-memory Keychain mock for testing.
final class FakeKeychainStorage: KeychainStorageProtocol, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()

    func save(data: Data, for key: String) throws {
        lock.withLock { store[key] = data }
    }

    func load(for key: String) throws -> Data? {
        lock.withLock { store[key] }
    }

    func delete(for key: String) throws {
        lock.withLock { store[key] = nil }
    }

    func exists(for key: String) throws -> Bool {
        lock.withLock { store[key] != nil }
    }

    /// Test helper: number of stored items.
    var count: Int {
        lock.withLock { store.count }
    }

    /// Test helper: clear all stored items.
    func clear() {
        lock.withLock { store.removeAll() }
    }
}

import Foundation
import Testing
@testable import RidestrSDK

@Suite("FakeKeychainStorage Tests")
struct KeychainStorageTests {
    @Test func saveAndLoad() throws {
        let storage = FakeKeychainStorage()
        let data = "test_value".data(using: .utf8)!
        try storage.save(data: data, for: "key1")
        let loaded = try storage.load(for: "key1")
        #expect(loaded == data)
    }

    @Test func loadMissingReturnsNil() throws {
        let storage = FakeKeychainStorage()
        let loaded = try storage.load(for: "nonexistent")
        #expect(loaded == nil)
    }

    @Test func overwrite() throws {
        let storage = FakeKeychainStorage()
        try storage.save(data: "first".data(using: .utf8)!, for: "key1")
        try storage.save(data: "second".data(using: .utf8)!, for: "key1")
        let loaded = try storage.load(for: "key1")
        #expect(loaded == "second".data(using: .utf8)!)
    }

    @Test func delete() throws {
        let storage = FakeKeychainStorage()
        try storage.save(data: "value".data(using: .utf8)!, for: "key1")
        try storage.delete(for: "key1")
        let loaded = try storage.load(for: "key1")
        #expect(loaded == nil)
    }

    @Test func deleteNonexistentDoesNotThrow() throws {
        let storage = FakeKeychainStorage()
        try storage.delete(for: "nonexistent")
    }

    @Test func exists() throws {
        let storage = FakeKeychainStorage()
        #expect(try !storage.exists(for: "key1"))
        try storage.save(data: "value".data(using: .utf8)!, for: "key1")
        #expect(try storage.exists(for: "key1"))
        try storage.delete(for: "key1")
        #expect(try !storage.exists(for: "key1"))
    }

    @Test func multipleKeys() throws {
        let storage = FakeKeychainStorage()
        try storage.save(data: "a".data(using: .utf8)!, for: "key_a")
        try storage.save(data: "b".data(using: .utf8)!, for: "key_b")
        #expect(storage.count == 2)
        #expect(try storage.load(for: "key_a") == "a".data(using: .utf8)!)
        #expect(try storage.load(for: "key_b") == "b".data(using: .utf8)!)
    }

    @Test func clearAll() throws {
        let storage = FakeKeychainStorage()
        try storage.save(data: "a".data(using: .utf8)!, for: "key_a")
        try storage.save(data: "b".data(using: .utf8)!, for: "key_b")
        storage.clear()
        #expect(storage.count == 0)
        #expect(try storage.load(for: "key_a") == nil)
    }
}

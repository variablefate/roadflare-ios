import Testing
@testable import RidestrSDK

@Suite("KeyManager Tests")
struct KeyManagerTests {
    @Test func noKeysOnFreshInit() async {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)
        let hasKeys = await manager.hasKeys
        #expect(!hasKeys)
        let keypair = await manager.getKeypair()
        #expect(keypair == nil)
    }

    @Test func generateAndRetrieve() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)
        let keypair = try await manager.generate()
        #expect(keypair.npub.hasPrefix("npub1"))
        let retrieved = await manager.getKeypair()
        #expect(retrieved == keypair)
        #expect(await manager.hasKeys)
    }

    @Test func generatePersistsToStorage() async throws {
        let storage = FakeKeychainStorage()
        let manager1 = KeyManager(storage: storage)
        let keypair = try await manager1.generate()

        // New manager with same storage should load the key
        let manager2 = KeyManager(storage: storage)
        let loaded = await manager2.getKeypair()
        #expect(loaded == keypair)
    }

    @Test func importNsec() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)

        let original = try NostrKeypair.generate()
        let imported = try await manager.importNsec(original.exportNsec())
        #expect(imported.publicKeyHex == original.publicKeyHex)
        #expect(await manager.hasKeys)
    }

    @Test func importHex() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)

        let original = try NostrKeypair.generate()
        let imported = try await manager.importHex(original.privateKeyHex)
        #expect(imported.publicKeyHex == original.publicKeyHex)
    }

    @Test func importOverwritesPrevious() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)

        let first = try await manager.generate()
        let second = try await manager.generate()
        #expect(first != second)

        let current = await manager.getKeypair()
        #expect(current == second)
    }

    @Test func exportNsec() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)
        let keypair = try await manager.generate()
        let nsec = try await manager.exportNsec()
        #expect(nsec == keypair.exportNsec())
    }

    @Test func exportNpub() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)
        let keypair = try await manager.generate()
        let npub = try await manager.exportNpub()
        #expect(npub == keypair.exportNpub())
    }

    @Test func exportWithoutKeysThrows() async {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)
        await #expect(throws: RidestrError.self) {
            try await manager.exportNsec()
        }
        await #expect(throws: RidestrError.self) {
            try await manager.exportNpub()
        }
    }

    @Test func deleteKeys() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)
        try await manager.generate()
        #expect(await manager.hasKeys)

        try await manager.deleteKeys()
        let hasKeysAfterDelete = await manager.hasKeys
        #expect(!hasKeysAfterDelete)
        let keypairAfterDelete = await manager.getKeypair()
        #expect(keypairAfterDelete == nil)

        // Verify storage is also cleared
        let manager2 = KeyManager(storage: storage)
        let hasKeysOnNewManager = await manager2.hasKeys
        #expect(!hasKeysOnNewManager)
    }
}

import Foundation

/// Manages the Nostr identity keypair lifecycle with Keychain persistence.
public actor KeyManager {
    private let storage: KeychainStorageProtocol
    private var currentKeypair: NostrKeypair?

    private static let privateKeyIdentifier = "nostr_identity_private_key"

    public init(storage: KeychainStorageProtocol) {
        self.storage = storage
        self.currentKeypair = Self.loadFromStorage(storage)
    }

    /// Whether a keypair is currently loaded.
    public var hasKeys: Bool {
        currentKeypair != nil
    }

    /// Get the current keypair, if one exists.
    public func getKeypair() -> NostrKeypair? {
        currentKeypair
    }

    /// Generate a new random keypair and persist it.
    @discardableResult
    public func generate() throws -> NostrKeypair {
        let keypair = try NostrKeypair.generate()
        try persist(keypair)
        currentKeypair = keypair
        return keypair
    }

    /// Import a keypair from an nsec bech32 string and persist it.
    @discardableResult
    public func importNsec(_ nsec: String) throws -> NostrKeypair {
        let keypair = try NostrKeypair.fromNsec(nsec)
        try persist(keypair)
        currentKeypair = keypair
        return keypair
    }

    /// Import a keypair from a hex private key and persist it.
    @discardableResult
    public func importHex(_ hex: String) throws -> NostrKeypair {
        let keypair = try NostrKeypair.fromHex(hex)
        try persist(keypair)
        currentKeypair = keypair
        return keypair
    }

    /// Export the current private key as nsec bech32.
    public func exportNsec() throws -> String {
        guard let keypair = currentKeypair else {
            throw RidestrError.invalidKey("No keypair loaded")
        }
        return keypair.exportNsec()
    }

    /// Export the current public key as npub bech32.
    public func exportNpub() throws -> String {
        guard let keypair = currentKeypair else {
            throw RidestrError.invalidKey("No keypair loaded")
        }
        return keypair.exportNpub()
    }

    /// Delete all keys from memory and Keychain.
    public func deleteKeys() throws {
        try storage.delete(for: Self.privateKeyIdentifier)
        currentKeypair = nil
    }

    /// Reload keypair from Keychain. Useful after app relaunch.
    public func refresh() {
        currentKeypair = Self.loadFromStorage(storage)
    }

    // MARK: - Private

    private func persist(_ keypair: NostrKeypair) throws {
        guard let data = keypair.privateKeyHex.data(using: .utf8) else {
            throw RidestrError.invalidKey("Failed to encode private key")
        }
        try storage.save(data: data, for: Self.privateKeyIdentifier)
    }

    private static func loadFromStorage(_ storage: KeychainStorageProtocol) -> NostrKeypair? {
        guard let data = try? storage.load(for: privateKeyIdentifier),
              let hex = String(data: data, encoding: .utf8) else {
            return nil
        }
        return try? NostrKeypair.fromHex(hex)
    }
}

import Foundation

/// Parses and decrypts incoming Nostr events for the Ridestr protocol.
public enum RideshareEventParser {

    // MARK: - Ride Acceptance (Kind 3174)

    /// Parse and decrypt a ride acceptance event.
    public static func parseAcceptance(
        event: NostrEvent,
        keypair: NostrKeypair
    ) throws -> RideAcceptanceContent {
        guard event.kind == EventKind.rideAcceptance.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3174, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Acceptance event has expired"))
        }
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: keypair,
            senderPublicKeyHex: event.pubkey
        )
        return try JSONDecoder().decode(RideAcceptanceContent.self, from: Data(decrypted.utf8))
    }

    // MARK: - Driver Ride State (Kind 30180)

    /// Parse and decrypt a driver ride state event.
    public static func parseDriverRideState(
        event: NostrEvent,
        keypair: NostrKeypair
    ) throws -> DriverRideStateContent {
        guard event.kind == EventKind.driverRideState.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 30180, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Driver ride state event has expired"))
        }
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: keypair,
            senderPublicKeyHex: event.pubkey
        )
        return try JSONDecoder().decode(DriverRideStateContent.self, from: Data(decrypted.utf8))
    }

    // MARK: - Chat Message (Kind 3178)

    /// Parse and decrypt a chat message.
    public static func parseChatMessage(
        event: NostrEvent,
        keypair: NostrKeypair
    ) throws -> ChatMessageContent {
        guard event.kind == EventKind.chatMessage.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3178, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Chat message has expired"))
        }
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: keypair,
            senderPublicKeyHex: event.pubkey
        )
        return try JSONDecoder().decode(ChatMessageContent.self, from: Data(decrypted.utf8))
    }

    // MARK: - Cancellation (Kind 3179)

    /// Parse and decrypt a cancellation event.
    public static func parseCancellation(
        event: NostrEvent,
        keypair: NostrKeypair
    ) throws -> CancellationContent {
        guard event.kind == EventKind.cancellation.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3179, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Cancellation event has expired"))
        }
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: keypair,
            senderPublicKeyHex: event.pubkey
        )
        return try JSONDecoder().decode(CancellationContent.self, from: Data(decrypted.utf8))
    }

    // MARK: - RoadFlare Key Share (Kind 3186)

    /// Parse and decrypt a RoadFlare key share event.
    public static func parseKeyShare(
        event: NostrEvent,
        keypair: NostrKeypair
    ) throws -> RoadflareKeyShareData {
        guard event.kind == EventKind.keyShare.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3186, got \(event.kind)"))
        }
        // Verify this key share is addressed to us
        guard event.referencedPubkeys.contains(keypair.publicKeyHex) else {
            throw RidestrError.ride(.invalidEvent("Key share not addressed to this user"))
        }
        // Check expiration
        if event.isExpired {
            throw RidestrError.ride(.invalidEvent("Key share has expired"))
        }

        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: keypair,
            senderPublicKeyHex: event.pubkey
        )
        let content = try JSONDecoder().decode(KeyShareContent.self, from: Data(decrypted.utf8))

        return RoadflareKeyShareData(
            eventId: event.id,
            driverPubkey: event.pubkey,
            roadflareKey: content.roadflareKey,
            keyUpdatedAt: content.keyUpdatedAt,
            createdAt: event.createdAt
        )
    }

    // MARK: - RoadFlare Location (Kind 30014)

    /// Parse and decrypt a RoadFlare location broadcast.
    /// Uses the shared RoadFlare private key (not identity key) for decryption.
    public static func parseRoadflareLocation(
        event: NostrEvent,
        roadflarePrivateKeyHex: String
    ) throws -> RoadflareLocationEvent {
        guard event.kind == EventKind.roadflareLocation.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 30014, got \(event.kind)"))
        }

        // Decrypt using RoadFlare privkey + driver's identity pubkey (ECDH commutativity)
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverPrivateKeyHex: roadflarePrivateKeyHex,
            senderPublicKeyHex: event.pubkey
        )
        let location = try JSONDecoder().decode(RoadflareLocation.self, from: Data(decrypted.utf8))

        return RoadflareLocationEvent(
            eventId: event.id,
            driverPubkey: event.pubkey,
            location: location,
            keyVersion: event.keyVersionTag ?? 0,
            tagStatus: event.statusTag,
            createdAt: event.createdAt
        )
    }

    // MARK: - Followed Drivers List (Kind 30011)

    /// Parse and decrypt the followed drivers list (own backup).
    public static func parseFollowedDriversList(
        event: NostrEvent,
        keypair: NostrKeypair
    ) throws -> FollowedDriversContent {
        guard event.kind == EventKind.followedDriversList.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 30011, got \(event.kind)"))
        }
        guard event.pubkey == keypair.publicKeyHex else {
            throw RidestrError.ride(.invalidEvent("Followed drivers list not authored by this user"))
        }
        let decrypted = try NIP44.decryptFromSelf(
            ciphertext: event.content,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )
        return try JSONDecoder().decode(FollowedDriversContent.self, from: Data(decrypted.utf8))
    }

    // MARK: - Helpers

    /// Extract PIN from a driver's pin_submit action (NIP-44 encrypted within the action).
    public static func decryptPin(
        pinEncrypted: String,
        driverPubkey: String,
        keypair: NostrKeypair
    ) throws -> String {
        try NIP44.decrypt(
            ciphertext: pinEncrypted,
            receiverKeypair: keypair,
            senderPublicKeyHex: driverPubkey
        )
    }

    /// Encrypt a location for a rider ride state LocationReveal action.
    public static func encryptLocation(
        location: Location,
        recipientPubkey: String,
        keypair: NostrKeypair
    ) throws -> String {
        let json = try JSONEncoder().encode(location)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(
                location, .init(codingPath: [], debugDescription: "Failed to encode location as UTF-8")
            )))
        }
        return try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: keypair,
            recipientPublicKeyHex: recipientPubkey
        )
    }
}

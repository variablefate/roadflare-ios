import Foundation

/// Parses and decrypts incoming Nostr events for the Ridestr protocol.
public enum RideshareEventParser {

    // MARK: - Profile Backup (Kind 30177)

    /// Parse and decrypt a profile backup event (Kind 30177, encrypted to self).
    public static func parseProfileBackup(
        event: NostrEvent,
        keypair: NostrKeypair
    ) throws -> ProfileBackupContent {
        guard event.kind == EventKind.unifiedProfile.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 30177, got \(event.kind)"))
        }
        guard event.pubkey == keypair.publicKeyHex else {
            throw RidestrError.ride(.invalidEvent("Profile backup not authored by this user"))
        }
        let decrypted = try NIP44.decryptFromSelf(
            ciphertext: event.content,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )
        return try JSONDecoder().decode(ProfileBackupContent.self, from: Data(decrypted.utf8))
    }

    // MARK: - User Profile (Kind 0)

    /// Parse a Kind 0 metadata event (plaintext JSON, no decryption needed).
    public static func parseMetadata(event: NostrEvent) -> UserProfileContent? {
        guard event.kind == EventKind.metadata.rawValue else { return nil }
        return UserProfileContent.fromJSON(event.content)
    }

    // MARK: - Ride Acceptance (Kind 3174)

    /// Parse ride-acceptance envelope metadata without decrypting the body.
    public static func parseAcceptanceEnvelope(
        event: NostrEvent,
        keypair: NostrKeypair,
        expectedDriverPubkey: String? = nil,
        expectedOfferEventId: String? = nil
    ) throws -> RideAcceptanceEnvelope {
        guard event.kind == EventKind.rideAcceptance.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3174, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Acceptance event has expired"))
        }
        guard event.referencedPubkeys.contains(keypair.publicKeyHex) else {
            throw RidestrError.ride(.invalidEvent("Acceptance not addressed to this user"))
        }
        if let expectedDriverPubkey, event.pubkey != expectedDriverPubkey {
            throw RidestrError.ride(.invalidEvent("Acceptance not authored by expected driver"))
        }
        guard let offerEventId = event.referencedEventIds.first else {
            throw RidestrError.ride(.invalidEvent("Acceptance missing offer event reference"))
        }
        if let expectedOfferEventId, offerEventId != expectedOfferEventId {
            throw RidestrError.ride(.invalidEvent("Acceptance does not reference expected offer"))
        }

        return RideAcceptanceEnvelope(
            eventId: event.id,
            driverPubkey: event.pubkey,
            offerEventId: offerEventId,
            riderPubkey: keypair.publicKeyHex,
            createdAt: event.createdAt
        )
    }

    /// Parse a ride acceptance event (plaintext JSON — not encrypted, matching Android).
    public static func parseAcceptance(
        event: NostrEvent,
        keypair: NostrKeypair,
        expectedDriverPubkey: String? = nil,
        expectedOfferEventId: String? = nil
    ) throws -> RideAcceptanceContent {
        _ = try parseAcceptanceEnvelope(
            event: event,
            keypair: keypair,
            expectedDriverPubkey: expectedDriverPubkey,
            expectedOfferEventId: expectedOfferEventId
        )
        // Android sends acceptance as plaintext JSON (not NIP-44 encrypted)
        let content = try JSONDecoder().decode(RideAcceptanceContent.self, from: Data(event.content.utf8))
        guard content.status == "accepted" else {
            throw RidestrError.ride(.invalidEvent("Acceptance content status must be accepted"))
        }
        return content
    }

    // MARK: - Ride Confirmation (Kind 3175)

    /// Parse ride-confirmation envelope metadata without decrypting the body.
    public static func parseConfirmationEnvelope(
        event: NostrEvent,
        expectedRiderPubkey: String? = nil,
        expectedDriverPubkey: String? = nil,
        expectedAcceptanceEventId: String? = nil
    ) throws -> RideConfirmationEnvelope {
        guard event.kind == EventKind.rideConfirmation.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3175, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Confirmation event has expired"))
        }
        if let expectedRiderPubkey, event.pubkey != expectedRiderPubkey {
            throw RidestrError.ride(.invalidEvent("Confirmation not authored by expected rider"))
        }
        guard let driverPubkey = event.referencedPubkeys.first else {
            throw RidestrError.ride(.invalidEvent("Confirmation missing driver pubkey tag"))
        }
        if let expectedDriverPubkey, driverPubkey != expectedDriverPubkey {
            throw RidestrError.ride(.invalidEvent("Confirmation not addressed to expected driver"))
        }
        guard let acceptanceEventId = event.referencedEventIds.first else {
            throw RidestrError.ride(.invalidEvent("Confirmation missing acceptance event reference"))
        }
        if let expectedAcceptanceEventId, acceptanceEventId != expectedAcceptanceEventId {
            throw RidestrError.ride(.invalidEvent("Confirmation does not reference expected acceptance"))
        }

        return RideConfirmationEnvelope(
            eventId: event.id,
            riderPubkey: event.pubkey,
            acceptanceEventId: acceptanceEventId,
            driverPubkey: driverPubkey,
            createdAt: event.createdAt
        )
    }

    // MARK: - Driver Ride State (Kind 30180)

    /// Parse a driver ride state event.
    ///
    /// The event envelope is plaintext JSON. Sensitive inner fields such as
    /// `pin_encrypted` remain NIP-44 encrypted inside the history payload.
    public static func parseDriverRideState(
        event: NostrEvent,
        keypair: NostrKeypair,
        expectedDriverPubkey: String? = nil,
        expectedConfirmationEventId: String? = nil
    ) throws -> DriverRideStateContent {
        guard event.kind == EventKind.driverRideState.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 30180, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Driver ride state event has expired"))
        }
        guard event.referencedPubkeys.contains(keypair.publicKeyHex) else {
            throw RidestrError.ride(.invalidEvent("Driver ride state not addressed to this user"))
        }
        if let expectedDriverPubkey, event.pubkey != expectedDriverPubkey {
            throw RidestrError.ride(.invalidEvent("Driver ride state not authored by expected driver"))
        }
        guard let confirmationEventId = event.dTag ?? event.referencedEventIds.first else {
            throw RidestrError.ride(.invalidEvent("Driver ride state missing confirmation reference"))
        }
        if let dTag = event.dTag,
           !event.referencedEventIds.isEmpty,
           !event.referencedEventIds.contains(dTag) {
            throw RidestrError.ride(.invalidEvent("Driver ride state d-tag does not match e-tag reference"))
        }
        if let expectedConfirmationEventId, confirmationEventId != expectedConfirmationEventId {
            throw RidestrError.ride(.invalidEvent("Driver ride state does not reference expected confirmation"))
        }
        return try JSONDecoder().decode(DriverRideStateContent.self, from: Data(event.content.utf8))
    }

    // MARK: - Rider Ride State (Kind 30181)

    /// Parse a rider ride state event.
    ///
    /// The event envelope is plaintext JSON. Sensitive inner fields such as
    /// `location_encrypted` remain NIP-44 encrypted inside the history payload.
    public static func parseRiderRideState(
        event: NostrEvent,
        keypair: NostrKeypair,
        expectedRiderPubkey: String? = nil,
        expectedConfirmationEventId: String? = nil
    ) throws -> RiderRideStateContent {
        guard event.kind == EventKind.riderRideState.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 30181, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Rider ride state event has expired"))
        }
        guard event.referencedPubkeys.contains(keypair.publicKeyHex) else {
            throw RidestrError.ride(.invalidEvent("Rider ride state not addressed to this user"))
        }
        if let expectedRiderPubkey, event.pubkey != expectedRiderPubkey {
            throw RidestrError.ride(.invalidEvent("Rider ride state not authored by expected rider"))
        }
        guard let confirmationEventId = event.dTag ?? event.referencedEventIds.first else {
            throw RidestrError.ride(.invalidEvent("Rider ride state missing confirmation reference"))
        }
        if let dTag = event.dTag,
           !event.referencedEventIds.isEmpty,
           !event.referencedEventIds.contains(dTag) {
            throw RidestrError.ride(.invalidEvent("Rider ride state d-tag does not match e-tag reference"))
        }
        if let expectedConfirmationEventId, confirmationEventId != expectedConfirmationEventId {
            throw RidestrError.ride(.invalidEvent("Rider ride state does not reference expected confirmation"))
        }
        return try JSONDecoder().decode(RiderRideStateContent.self, from: Data(event.content.utf8))
    }

    // MARK: - Chat Message (Kind 3178)

    /// Parse and decrypt a chat message.
    public static func parseChatMessage(
        event: NostrEvent,
        keypair: NostrKeypair,
        expectedSenderPubkey: String? = nil,
        expectedConfirmationEventId: String? = nil
    ) throws -> ChatMessageContent {
        guard event.kind == EventKind.chatMessage.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3178, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Chat message has expired"))
        }
        guard event.referencedPubkeys.contains(keypair.publicKeyHex) else {
            throw RidestrError.ride(.invalidEvent("Chat message not addressed to this user"))
        }
        if let expectedSenderPubkey, event.pubkey != expectedSenderPubkey {
            throw RidestrError.ride(.invalidEvent("Chat message not authored by expected sender"))
        }
        guard let confirmationEventId = event.referencedEventIds.first else {
            throw RidestrError.ride(.invalidEvent("Chat message missing confirmation reference"))
        }
        if let expectedConfirmationEventId, confirmationEventId != expectedConfirmationEventId {
            throw RidestrError.ride(.invalidEvent("Chat message does not reference expected confirmation"))
        }
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: keypair,
            senderPublicKeyHex: event.pubkey
        )
        return try JSONDecoder().decode(ChatMessageContent.self, from: Data(decrypted.utf8))
    }

    // MARK: - Cancellation (Kind 3179)

    /// Parse a cancellation event.
    ///
    /// The event envelope is plaintext JSON, matching the shared Android/common protocol.
    public static func parseCancellation(
        event: NostrEvent,
        keypair: NostrKeypair,
        expectedDriverPubkey: String? = nil,
        expectedConfirmationEventId: String? = nil
    ) throws -> CancellationContent {
        guard event.kind == EventKind.cancellation.rawValue else {
            throw RidestrError.ride(.invalidEvent("Expected Kind 3179, got \(event.kind)"))
        }
        guard !event.isExpired else {
            throw RidestrError.ride(.invalidEvent("Cancellation event has expired"))
        }
        guard event.referencedPubkeys.contains(keypair.publicKeyHex) else {
            throw RidestrError.ride(.invalidEvent("Cancellation not addressed to this user"))
        }
        if let expectedDriverPubkey, event.pubkey != expectedDriverPubkey {
            throw RidestrError.ride(.invalidEvent("Cancellation not authored by expected driver"))
        }
        if let expectedConfirmationEventId, !event.referencedEventIds.contains(expectedConfirmationEventId) {
            throw RidestrError.ride(.invalidEvent("Cancellation does not reference expected confirmation event"))
        }
        let content = try JSONDecoder().decode(CancellationContent.self, from: Data(event.content.utf8))
        guard content.status == "cancelled" else {
            throw RidestrError.ride(.invalidEvent("Cancellation content status must be cancelled"))
        }
        return content
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
        // Check expiration (only applies to legacy Kind 3186 with NIP-40 expiration tag)
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

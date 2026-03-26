import Foundation

/// Builds unsigned Nostr events for the Ridestr rideshare protocol.
/// Each method constructs the tags, encrypts content as needed, and returns a signed event.
///
/// All builder methods validate inputs before encryption:
/// - Public keys must be 64-character hex strings
/// - Event IDs must be non-empty
/// - Locations must have valid coordinates (if provided)
public enum RideshareEventBuilder {

    // MARK: - Input Validation

    /// Validate a hex public key (64 hex characters).
    /// - Parameter pubkey: The hex string to validate.
    /// - Parameter label: Human-readable label for error messages (default "Public key").
    /// - Throws: `RidestrError.crypto(.invalidKey(...))` if validation fails.
    public static func validatePubkey(_ pubkey: String, label: String = "Public key") throws {
        guard pubkey.count == 64, pubkey.allSatisfy(\.isHexDigit) else {
            throw RidestrError.crypto(.invalidKey("\(label) must be 64 hex characters, got \(pubkey.count) chars"))
        }
    }

    /// Validate a Nostr event ID (64 hex characters).
    private static func validateEventId(_ eventId: String, label: String = "Event ID") throws {
        guard eventId.count == 64, eventId.allSatisfy(\.isHexDigit) else {
            throw RidestrError.ride(.invalidEvent("\(label) must be 64 hex characters, got \(eventId.count) chars"))
        }
    }

    // MARK: - Ride Offer (Kind 3173)

    /// Build and sign a RoadFlare ride offer.
    ///
    /// - Parameters:
    ///   - driverPubkey: The driver's 64-character hex public key.
    ///   - driverAvailabilityEventId: Optional event ID of the driver's availability event.
    ///   - content: The ride offer content (fare, locations, payment methods).
    ///   - keypair: The rider's signing keypair.
    /// - Returns: A signed, encrypted Nostr event (Kind 3173).
    /// - Throws: `RidestrError.crypto` if encryption fails, `.ride` if inputs invalid.
    public static func rideOffer(
        driverPubkey: String,
        driverAvailabilityEventId: String?,
        content: RideOfferContent,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        try validatePubkey(driverPubkey, label: "Driver pubkey")
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed"))))
        }

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: keypair,
            recipientPublicKeyHex: driverPubkey
        )

        var tags: [[String]] = [
            [NostrTags.pubkeyRef, driverPubkey],
            [NostrTags.hashtag, NostrTags.rideshareTag],
            [NostrTags.hashtag, NostrTags.roadflareTag],
        ]

        if let availId = driverAvailabilityEventId {
            tags.append([NostrTags.eventRef, availId])
        }

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.rideOfferMinutes * 60)
        tags.append([NostrTags.expiration, String(expiry)])

        return try await EventSigner.sign(
            kind: .rideOffer, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - Ride Confirmation (Kind 3175)

    /// Build and sign a ride confirmation with PIN and precise pickup.
    ///
    /// - Parameters:
    ///   - driverPubkey: The driver's 64-character hex public key.
    ///   - acceptanceEventId: The acceptance event ID (Kind 3174) being confirmed.
    ///   - precisePickup: The rider's precise pickup location (shared with driver).
    ///   - keypair: The rider's signing keypair.
    /// - Returns: A signed, encrypted Nostr event (Kind 3175).
    /// - Throws: `RidestrError.crypto` if encryption fails, `.ride` if inputs invalid.
    public static func rideConfirmation(
        driverPubkey: String,
        acceptanceEventId: String,
        precisePickup: Location,
        paymentHash: String? = nil,
        escrowToken: String? = nil,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        try validatePubkey(driverPubkey, label: "Driver pubkey")
        try validateEventId(acceptanceEventId, label: "Acceptance event ID")
        let content = RideConfirmationContent(
            precisePickup: precisePickup,
            paymentHash: paymentHash,
            escrowToken: escrowToken
        )
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed"))))
        }

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: keypair,
            recipientPublicKeyHex: driverPubkey
        )

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.rideConfirmationHours * 3600)
        let tags: [[String]] = [
            [NostrTags.eventRef, acceptanceEventId],
            [NostrTags.pubkeyRef, driverPubkey],
            [NostrTags.hashtag, NostrTags.rideshareTag],
            [NostrTags.expiration, String(expiry)],
        ]

        return try await EventSigner.sign(
            kind: .rideConfirmation, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - Rider Ride State (Kind 30181)

    /// Build and sign a rider ride state update.
    ///
    /// - Parameters:
    ///   - driverPubkey: The driver's 64-character hex public key.
    ///   - confirmationEventId: The confirmation event ID (Kind 3175) for this ride.
    ///   - phase: The rider's current phase string (e.g., "awaiting_driver", "verified").
    ///   - history: The rider's action history array.
    ///   - keypair: The rider's signing keypair.
    /// The event envelope is plaintext JSON, matching the shared Android/common protocol.
    /// Sensitive inner fields such as `location_encrypted` are individually NIP-44 encrypted
    /// before being added to the history.
    ///
    /// - Returns: A signed Nostr event (Kind 30181).
    /// - Throws: `.ride` if inputs invalid.
    public static func riderRideState(
        driverPubkey: String,
        confirmationEventId: String,
        phase: String,
        history: [RiderRideAction],
        keypair: NostrKeypair,
        lastTransitionId: String? = nil
    ) async throws -> NostrEvent {
        try validatePubkey(driverPubkey, label: "Driver pubkey")
        try validateEventId(confirmationEventId, label: "Confirmation event ID")
        let content = RiderRideStateContent(currentPhase: phase, history: history)
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed"))))
        }

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.rideStateHours * 3600)
        var tags: [[String]] = [
            [NostrTags.dTag, confirmationEventId],
            [NostrTags.eventRef, confirmationEventId],
            [NostrTags.pubkeyRef, driverPubkey],
            [NostrTags.hashtag, NostrTags.rideshareTag],
            [NostrTags.expiration, String(expiry)],
        ]
        if let lastTransitionId {
            tags.append(["transition", lastTransitionId])
        }

        return try await EventSigner.sign(
            kind: .riderRideState, content: plaintext, tags: tags, keypair: keypair
        )
    }

    // MARK: - Chat Message (Kind 3178)

    /// Build and sign an encrypted chat message.
    ///
    /// - Parameters:
    ///   - recipientPubkey: The recipient's 64-character hex public key.
    ///   - confirmationEventId: The confirmation event ID linking this message to a ride.
    ///   - message: The plaintext message content.
    ///   - keypair: The sender's signing keypair.
    /// - Returns: A signed, encrypted Nostr event (Kind 3178).
    public static func chatMessage(
        recipientPubkey: String,
        confirmationEventId: String,
        message: String,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        try validatePubkey(recipientPubkey, label: "Recipient pubkey")
        try validateEventId(confirmationEventId, label: "Confirmation event ID")
        let content = ChatMessageContent(message: message)
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed"))))
        }

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: keypair,
            recipientPublicKeyHex: recipientPubkey
        )

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.chatHours * 3600)
        let tags: [[String]] = [
            [NostrTags.pubkeyRef, recipientPubkey],
            [NostrTags.eventRef, confirmationEventId],
            [NostrTags.hashtag, NostrTags.rideshareTag],
            [NostrTags.expiration, String(expiry)],
        ]

        return try await EventSigner.sign(
            kind: .chatMessage, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - Cancellation (Kind 3179)

    /// Build and sign a ride cancellation.
    ///
    /// - Parameters:
    ///   - counterpartyPubkey: The other party's 64-character hex public key.
    ///   - confirmationEventId: The confirmation event ID for the ride being cancelled.
    ///   - reason: Optional human-readable cancellation reason.
    ///   - keypair: The cancelling party's signing keypair.
    /// The event envelope is plaintext JSON, matching the shared Android/common protocol.
    ///
    /// - Returns: A signed Nostr event (Kind 3179).
    public static func cancellation(
        counterpartyPubkey: String,
        confirmationEventId: String,
        reason: String?,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        try validatePubkey(counterpartyPubkey, label: "Counterparty pubkey")
        try validateEventId(confirmationEventId, label: "Confirmation event ID")
        let content = CancellationContent(reason: reason)
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(
                content, .init(codingPath: [], debugDescription: "Failed to encode cancellation as UTF-8")
            )))
        }

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.cancellationHours * 3600)
        let tags: [[String]] = [
            [NostrTags.pubkeyRef, counterpartyPubkey],
            [NostrTags.eventRef, confirmationEventId],
            [NostrTags.hashtag, NostrTags.rideshareTag],
            [NostrTags.expiration, String(expiry)],
        ]

        return try await EventSigner.sign(
            kind: .cancellation, content: plaintext, tags: tags, keypair: keypair
        )
    }

    // MARK: - Followed Drivers List (Kind 30011)

    /// Build and sign the followed drivers list (encrypted to self, p-tags public).
    ///
    /// The content is NIP-44 encrypted to the rider's own keypair. Public p-tags
    /// allow driver discovery without revealing the full relationship data.
    ///
    /// - Parameters:
    // MARK: - Profile Backup (Kind 30177)

    /// Build and sign an encrypted profile backup event (Kind 30177).
    /// Contains saved locations, settings (payment methods, preferences).
    /// Content is NIP-44 encrypted to self.
    public static func profileBackup(
        content: ProfileBackupContent,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(
                content, .init(codingPath: [], debugDescription: "Failed to encode profile backup as UTF-8")
            )))
        }
        let encrypted = try NIP44.encryptToSelf(
            plaintext: plaintext,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )
        let tags: [[String]] = [
            [NostrTags.dTag, "rideshare-profile"],
            [NostrTags.hashtag, NostrTags.roadflareTag],
        ]
        return try await EventSigner.sign(
            kind: .unifiedProfile, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - Event Deletion (NIP-09, Kind 5)

    /// Build and sign a NIP-09 deletion event (Kind 5).
    /// Requests relays to delete the specified events.
    public static func deletion(
        eventIds: [String],
        reason: String = "",
        kinds: [EventKind]? = nil,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        var tags: [[String]] = eventIds.map { [NostrTags.eventRef, $0] }
        if let kinds {
            for kind in Set(kinds) {
                tags.append(["k", String(kind.rawValue)])
            }
        }
        return try await EventSigner.sign(
            kind: 5, content: reason, tags: tags, keypair: keypair
        )
    }

    // MARK: - Follow Notification (Kind 3187)

    /// Build and sign a follow notification event (Kind 3187).
    /// Sent by a rider to a driver as a real-time push when adding them.
    /// Content is NIP-44 encrypted to the driver's pubkey.
    /// Short expiry (5 minutes) — this is just a nudge, not the source of truth.
    /// The rider's Kind 30011 p-tags are the actual source of truth for follows.
    public static func followNotification(
        driverPubkey: String,
        riderName: String,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        try validatePubkey(driverPubkey, label: "Driver pubkey")

        let content: [String: Any] = [
            "action": "follow",
            "riderName": riderName,
            "timestamp": Int(Date.now.timeIntervalSince1970)
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: content),
              let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: NSError(domain: "JSON", code: 0)))
        }

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: keypair.privateKeyHex,
            recipientPublicKeyHex: driverPubkey
        )

        let expiration = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.roadflareFollowNotifyMinutes * 60)
        let tags: [[String]] = [
            [NostrTags.pubkeyRef, driverPubkey],
            [NostrTags.hashtag, "roadflare-follow"],
            ["expiration", String(expiration)]
        ]

        return try await EventSigner.sign(
            kind: .followNotification, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - User Profile (Kind 0)

    /// Build and sign a NIP-01 metadata event (Kind 0).
    /// Content is plaintext JSON (not encrypted).
    public static func metadata(
        profile: UserProfileContent,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        try await EventSigner.sign(
            kind: .metadata,
            content: profile.toJSON(),
            tags: [],
            keypair: keypair
        )
    }

    // MARK: - Followed Drivers List (Kind 30011)

    ///   - drivers: The rider's list of followed drivers.
    ///   - keypair: The rider's signing keypair (encrypts to self).
    /// - Returns: A signed, self-encrypted Nostr event (Kind 30011).
    /// - Throws: `RidestrError.crypto` if encryption fails.
    public static func followedDriversList(
        drivers: [FollowedDriver],
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let entries = drivers.map { driver in
            FollowedDriverEntry(
                pubkey: driver.pubkey,
                addedAt: driver.addedAt,
                note: driver.note,
                roadflareKey: driver.roadflareKey
            )
        }
        let content = FollowedDriversContent(
            drivers: entries,
            updatedAt: Int(Date.now.timeIntervalSince1970)
        )
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(
                content, .init(codingPath: [], debugDescription: "Failed to encode followed drivers as UTF-8")
            )))
        }

        let encrypted = try NIP44.encryptToSelf(
            plaintext: plaintext,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )

        // Public p-tags for driver discovery
        var tags: [[String]] = [
            [NostrTags.dTag, "roadflare-drivers"],
            [NostrTags.hashtag, NostrTags.roadflareTag],
        ]
        for driver in drivers {
            tags.append([NostrTags.pubkeyRef, driver.pubkey])
        }

        return try await EventSigner.sign(
            kind: .followedDriversList, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - Key Acknowledgement (Kind 3188)

    /// Build and sign a key acknowledgement to a driver.
    ///
    /// - Parameters:
    ///   - driverPubkey: The driver's 64-character hex public key.
    ///   - keyVersion: The RoadFlare key version being acknowledged.
    ///   - keyUpdatedAt: Timestamp when the key was updated.
    ///   - status: Acknowledgement status ("received" or "stale").
    ///   - keypair: The rider's signing keypair.
    /// - Returns: A signed, encrypted Nostr event (Kind 3188).
    /// - Throws: `RidestrError.crypto` if encryption fails, `.ride` if inputs invalid.
    public static func keyAcknowledgement(
        driverPubkey: String,
        keyVersion: Int,
        keyUpdatedAt: Int,
        status: String,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        try validatePubkey(driverPubkey, label: "Driver pubkey")
        let content = KeyAckContent(
            keyVersion: keyVersion,
            keyUpdatedAt: keyUpdatedAt,
            status: status,
            riderPubKey: keypair.publicKeyHex
        )
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.crypto(.encryptionFailed(underlying: EncodingError.invalidValue(
                content, .init(codingPath: [], debugDescription: "Failed to encode key ack as UTF-8")
            )))
        }

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: keypair,
            recipientPublicKeyHex: driverPubkey
        )

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.roadflareKeyAckMinutes * 60)
        let tags: [[String]] = [
            [NostrTags.pubkeyRef, driverPubkey],
            [NostrTags.hashtag, NostrTags.roadflareKeyAckTag],
            [NostrTags.expiration, String(expiry)],
        ]

        return try await EventSigner.sign(
            kind: .keyAcknowledgement, content: encrypted, tags: tags, keypair: keypair
        )
    }
}

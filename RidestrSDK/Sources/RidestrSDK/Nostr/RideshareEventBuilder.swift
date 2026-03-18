import Foundation

/// Builds unsigned Nostr events for the Ridestr rideshare protocol.
/// Each method constructs the tags, encrypts content as needed, and returns a signed event.
public enum RideshareEventBuilder {

    // MARK: - Ride Offer (Kind 3173)

    /// Build and sign a RoadFlare ride offer.
    public static func rideOffer(
        driverPubkey: String,
        driverAvailabilityEventId: String?,
        content: RideOfferContent,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed")))
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
    public static func rideConfirmation(
        driverPubkey: String,
        acceptanceEventId: String,
        precisePickup: Location?,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let content = RideConfirmationContent(precisePickup: precisePickup)
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed")))
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
    public static func riderRideState(
        driverPubkey: String,
        confirmationEventId: String,
        phase: String,
        history: [RiderRideAction],
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let content = RiderRideStateContent(currentPhase: phase, history: history)
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed")))
        }

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: keypair,
            recipientPublicKeyHex: driverPubkey
        )

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.rideStateHours * 3600)
        let tags: [[String]] = [
            [NostrTags.dTag, confirmationEventId],
            [NostrTags.pubkeyRef, driverPubkey],
            [NostrTags.hashtag, NostrTags.rideshareTag],
            [NostrTags.expiration, String(expiry)],
        ]

        return try await EventSigner.sign(
            kind: .riderRideState, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - Chat Message (Kind 3178)

    /// Build and sign an encrypted chat message.
    public static func chatMessage(
        recipientPubkey: String,
        confirmationEventId: String,
        message: String,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let content = ChatMessageContent(message: message)
        let json = try JSONEncoder().encode(content)
        guard let plaintext = String(data: json, encoding: .utf8) else {
            throw RidestrError.encryptionFailed(underlying: EncodingError.invalidValue(content, .init(codingPath: [], debugDescription: "UTF8 encoding failed")))
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
    public static func cancellation(
        counterpartyPubkey: String,
        confirmationEventId: String,
        reason: String?,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let content = CancellationContent(reason: reason)
        let json = try JSONEncoder().encode(content)
        let plaintext = String(data: json, encoding: .utf8) ?? "{}"

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: keypair,
            recipientPublicKeyHex: counterpartyPubkey
        )

        let expiry = Int(Date.now.timeIntervalSince1970) + Int(EventExpiration.cancellationHours * 3600)
        let tags: [[String]] = [
            [NostrTags.pubkeyRef, counterpartyPubkey],
            [NostrTags.eventRef, confirmationEventId],
            [NostrTags.hashtag, NostrTags.rideshareTag],
            [NostrTags.expiration, String(expiry)],
        ]

        return try await EventSigner.sign(
            kind: .cancellation, content: encrypted, tags: tags, keypair: keypair
        )
    }

    // MARK: - Followed Drivers List (Kind 30011)

    /// Build and sign the followed drivers list (encrypted to self, p-tags public).
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
        let plaintext = String(data: json, encoding: .utf8) ?? "{}"

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
    public static func keyAcknowledgement(
        driverPubkey: String,
        keyVersion: Int,
        keyUpdatedAt: Int,
        status: String,
        keypair: NostrKeypair
    ) async throws -> NostrEvent {
        let content = KeyAckContent(
            keyVersion: keyVersion,
            keyUpdatedAt: keyUpdatedAt,
            status: status,
            riderPubKey: keypair.publicKeyHex
        )
        let json = try JSONEncoder().encode(content)
        let plaintext = String(data: json, encoding: .utf8) ?? "{}"

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

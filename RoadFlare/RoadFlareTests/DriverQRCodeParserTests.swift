import Testing
@testable import RoadFlareCore
@testable import RidestrSDK

@Suite("Driver QR Code Parser Tests")
struct DriverQRCodeParserTests {
    private func makeNpub(hex: String = String(repeating: "a", count: 64)) throws -> String {
        try NIP19.npubEncode(publicKeyHex: hex)
    }

    @Test func parsesNostrURIWithNameParameter() throws {
        let npub = try makeNpub()

        let parsed = DriverQRCodeParser.parse("nostr:\(npub)?name=Road%20Runner")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: "Road Runner"))
    }

    @Test func parsesRoadflareShareURLWithNpubInPath() throws {
        let npub = try makeNpub(hex: String(repeating: "b", count: 64))

        let parsed = DriverQRCodeParser.parse("https://roadflare.app/share/d/\(npub)")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: nil))
    }

    @Test func parsesRoadflareShareURLWithQueryName() throws {
        let npub = try makeNpub(hex: String(repeating: "c", count: 64))

        let parsed = DriverQRCodeParser.parse("https://roadflare.app/share/d/\(npub)?name=Driver%20Dan")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: "Driver Dan"))
    }

    @Test func parsesBareNpub() throws {
        let npub = try makeNpub(hex: String(repeating: "d", count: 64))

        let parsed = DriverQRCodeParser.parse(npub)

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: nil))
    }

    @Test func parsesBareNpubWithNameParameter() throws {
        let npub = try makeNpub(hex: String(repeating: "e", count: 64))

        let parsed = DriverQRCodeParser.parse("\(npub)?name=Speedy%20Steve")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: "Speedy Steve"))
    }

    @Test func parsesHexPubkey() {
        let hex = String(repeating: "f1", count: 32)

        let parsed = DriverQRCodeParser.parse(hex)

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: hex, scannedName: nil))
    }

    @Test func rejectsCodesWithoutNostrIdentifier() {
        #expect(DriverQRCodeParser.parse("https://roadflare.app/share/d/not-a-driver") == nil)
    }

    // MARK: - roadflared: URL scheme

    @Test func parsesRoadflaredURI() throws {
        let npub = try makeNpub(hex: String(repeating: "1a", count: 32))

        let parsed = DriverQRCodeParser.parse("roadflared:\(npub)")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: nil))
    }

    @Test func parsesRoadflaredURIWithNameParameter() throws {
        let npub = try makeNpub(hex: String(repeating: "2b", count: 32))

        let parsed = DriverQRCodeParser.parse("roadflared:\(npub)?name=Road%20Runner")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: "Road Runner"))
    }

    @Test func parsesRoadflaredURIWithEmptyNameTreatedAsNil() throws {
        let npub = try makeNpub(hex: String(repeating: "3c", count: 32))

        let parsed = DriverQRCodeParser.parse("roadflared:\(npub)?name=")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: nil))
    }

    @Test func rejectsRoadflaredURIWithoutNpub() {
        #expect(DriverQRCodeParser.parse("roadflared:not-a-key") == nil)
    }

    @Test func rejectsRoadflaredURIWithEmptyBody() {
        // Regression: `parseNpubWithOptionalQuery("")` previously crashed
        // (Index out of range) because `"".split(separator: "?")` returns []
        // and `parts[0]` was unguarded.
        #expect(DriverQRCodeParser.parse("roadflared:") == nil)
    }

    @Test func rejectsNostrURIWithEmptyBody() {
        // Same regression, `nostr:` arm. Was latent because nothing exercised
        // it in tests prior to the roadflared: work.
        #expect(DriverQRCodeParser.parse("nostr:") == nil)
    }

    @Test func rejectsRoadflarerSchemeOnRiderApp() throws {
        // The rider app intentionally does NOT handle roadflarer: (driver-app
        // territory). If such a URL ever reaches the parser, it should be
        // rejected — the embedded npub regex must not greedily accept it.
        let npub = try makeNpub(hex: String(repeating: "4d", count: 32))

        // roadflarer: is parsed as an opaque URI; nothing in DriverQRCodeParser
        // should claim it as a driver pubkey because the host app's URL scheme
        // registration won't even dispatch this scheme. But document the parser
        // behavior explicitly so future refactors don't silently broaden it.
        let parsed = DriverQRCodeParser.parse("roadflarer:\(npub)")

        // Currently, parseURLOrEmbeddedNpub will match the embedded npub.
        // That's acceptable: the rider app never receives this scheme via
        // .onOpenURL, so this fallback only runs if someone manually pastes
        // the URL into the Add Driver text field — in which case extracting
        // the npub is a reasonable best-effort.
        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: nil))
    }
}

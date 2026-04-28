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

    @Test func acceptsRoadflarerSchemeViaEmbeddedNpubFallback() throws {
        // The rider app does NOT register `roadflarer:` as a URL scheme (that's
        // reserved for the future driver app), so this URL never arrives via
        // .onOpenURL. But if a user manually pastes such a URL into the Add
        // Driver text field, `parseURLOrEmbeddedNpub` will extract the npub via
        // the regex fallback — a reasonable best-effort. This test pins that
        // behavior so future parser refactors don't silently change it.
        let npub = try makeNpub(hex: String(repeating: "4d", count: 32))

        let parsed = DriverQRCodeParser.parse("roadflarer:\(npub)")

        #expect(parsed == ParsedDriverQRCode(pubkeyInput: npub, scannedName: nil))
    }
}

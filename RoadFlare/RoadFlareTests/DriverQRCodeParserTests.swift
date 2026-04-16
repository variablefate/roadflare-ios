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

    @Test func rejectsCodesWithoutNostrIdentifier() {
        #expect(DriverQRCodeParser.parse("https://roadflare.app/share/d/not-a-driver") == nil)
    }
}

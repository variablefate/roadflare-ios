import Testing
@testable import RoadFlareCore
@testable import RidestrSDK

@Suite("Driver Lookup Draft Tests")
struct DriverLookupDraftTests {
    private func makeNpub(hex: String = String(repeating: "a", count: 64)) throws -> String {
        try NIP19.npubEncode(publicKeyHex: hex)
    }

    @Test func inputChangeClearsStaleScanNameAndError() {
        var draft = DriverLookupDraft(
            pubkeyInput: "old-input",
            errorMessage: "Invalid npub format",
            scannedName: "Alice"
        )

        draft.updatePubkeyInput("new-input")

        #expect(draft.pubkeyInput == "new-input")
        #expect(draft.errorMessage == nil)
        #expect(draft.scannedName == nil)
    }

    @Test func resolveLookupForShareURLClearsPreviousScannedName() throws {
        let npub = try makeNpub(hex: String(repeating: "b", count: 64))
        var draft = DriverLookupDraft(scannedName: "Alice")

        draft.updatePubkeyInput("https://roadflare.app/share/d/\(npub)")
        let lookup = draft.resolveLookup()
        let resolvedLookup = try #require(lookup)

        #expect(draft.scannedName == nil)
        #expect(resolvedLookup.parsedQRCode.scannedName == nil)
        #expect(resolvedLookup.hexPubkey == String(repeating: "b", count: 64))
    }

    @Test func invalidScannedCodeClearsStaleScanName() {
        var draft = DriverLookupDraft(scannedName: "Alice")

        let parsed = draft.applyScannedCode("https://roadflare.app/share/d/not-a-driver")

        #expect(parsed == nil)
        #expect(draft.scannedName == nil)
        #expect(draft.errorMessage == "QR code doesn't contain a valid Nostr public key")
    }
}

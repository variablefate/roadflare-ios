import Testing
@testable import RidestrSDK

@Suite("NostrKeypair Tests")
struct NostrKeypairTests {
    @Test func generate() throws {
        let keypair = try NostrKeypair.generate()
        #expect(keypair.publicKeyHex.count == 64)
        #expect(keypair.npub.hasPrefix("npub1"))
        #expect(keypair.nsec.hasPrefix("nsec1"))
        #expect(keypair.privateKeyHex.count == 64)
    }

    @Test func generateProducesUniqueKeys() throws {
        let a = try NostrKeypair.generate()
        let b = try NostrKeypair.generate()
        #expect(a.publicKeyHex != b.publicKeyHex)
        #expect(a.privateKeyHex != b.privateKeyHex)
    }

    @Test func fromNsecRoundtrip() throws {
        let original = try NostrKeypair.generate()
        let nsec = original.exportNsec()
        let restored = try NostrKeypair.fromNsec(nsec)
        #expect(original.publicKeyHex == restored.publicKeyHex)
        #expect(original.npub == restored.npub)
    }

    @Test func fromHexRoundtrip() throws {
        let original = try NostrKeypair.generate()
        let restored = try NostrKeypair.fromHex(original.privateKeyHex)
        #expect(original.publicKeyHex == restored.publicKeyHex)
    }

    @Test func invalidNsecThrows() {
        #expect(throws: RidestrError.self) {
            try NostrKeypair.fromNsec("nsec1invalid")
        }
    }

    @Test func invalidHexThrows() {
        #expect(throws: RidestrError.self) {
            try NostrKeypair.fromHex("not-a-hex-key")
        }
    }

    @Test func emptyStringThrows() {
        #expect(throws: RidestrError.self) {
            try NostrKeypair.fromNsec("")
        }
        #expect(throws: RidestrError.self) {
            try NostrKeypair.fromHex("")
        }
    }

    @Test func exportNsec() throws {
        let keypair = try NostrKeypair.generate()
        let nsec = keypair.exportNsec()
        #expect(nsec.hasPrefix("nsec1"))
        #expect(nsec == keypair.nsec)
    }

    @Test func exportNpub() throws {
        let keypair = try NostrKeypair.generate()
        let npub = keypair.exportNpub()
        #expect(npub.hasPrefix("npub1"))
        #expect(npub == keypair.npub)
    }

    @Test func equatable() throws {
        let keypair = try NostrKeypair.generate()
        let same = try NostrKeypair.fromHex(keypair.privateKeyHex)
        let different = try NostrKeypair.generate()
        #expect(keypair == same)
        #expect(keypair != different)
    }
}

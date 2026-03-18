import Foundation
import Testing
@testable import RidestrSDK

@Suite("NIP-19 Tests")
struct NIP19Tests {
    @Test func npubEncodeAndDecode() throws {
        let keypair = try NostrKeypair.generate()
        let npub = try NIP19.npubEncode(publicKeyHex: keypair.publicKeyHex)
        #expect(npub.hasPrefix("npub1"))
        let decoded = try NIP19.npubDecode(npub)
        #expect(decoded == keypair.publicKeyHex)
    }

    @Test func nsecEncodeAndDecode() throws {
        let keypair = try NostrKeypair.generate()
        let nsec = try NIP19.nsecEncode(privateKeyHex: keypair.privateKeyHex)
        #expect(nsec.hasPrefix("nsec1"))
        let decoded = try NIP19.nsecDecode(nsec)
        #expect(decoded == keypair.privateKeyHex)
    }

    @Test func npubDecodeFromKeypair() throws {
        let keypair = try NostrKeypair.generate()
        let hex = try NIP19.npubDecode(keypair.npub)
        #expect(hex == keypair.publicKeyHex)
    }

    @Test func nsecDecodeFromKeypair() throws {
        let keypair = try NostrKeypair.generate()
        let hex = try NIP19.nsecDecode(keypair.nsec)
        #expect(hex == keypair.privateKeyHex)
    }

    @Test func invalidNpubThrows() {
        #expect(throws: RidestrError.self) {
            try NIP19.npubDecode("npub1invalid")
        }
    }

    @Test func invalidNsecThrows() {
        #expect(throws: RidestrError.self) {
            try NIP19.nsecDecode("nsec1invalid")
        }
    }

    @Test func garbageStringThrows() {
        #expect(throws: RidestrError.self) {
            try NIP19.npubDecode("hello world")
        }
        #expect(throws: RidestrError.self) {
            try NIP19.nsecDecode("hello world")
        }
    }

    @Test func isValidNpub() throws {
        let keypair = try NostrKeypair.generate()
        #expect(NIP19.isValidNpub(keypair.npub))
        #expect(!NIP19.isValidNpub("npub1invalid"))
        #expect(!NIP19.isValidNpub(""))
        #expect(!NIP19.isValidNpub(keypair.nsec))  // nsec is not a valid npub
    }

    @Test func isValidNsec() throws {
        let keypair = try NostrKeypair.generate()
        #expect(NIP19.isValidNsec(keypair.nsec))
        #expect(!NIP19.isValidNsec("nsec1invalid"))
        #expect(!NIP19.isValidNsec(""))
        #expect(!NIP19.isValidNsec(keypair.npub))  // npub is not a valid nsec
    }

    @Test func isValidHexPubkey() throws {
        let keypair = try NostrKeypair.generate()
        #expect(NIP19.isValidHexPubkey(keypair.publicKeyHex))
        #expect(!NIP19.isValidHexPubkey("tooshort"))
        #expect(!NIP19.isValidHexPubkey(""))
        #expect(!NIP19.isValidHexPubkey(keypair.npub))  // bech32 is not hex
    }
}

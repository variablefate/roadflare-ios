import Foundation
import RidestrSDK

public struct ResolvedDriverLookup: Equatable {
    public let hexPubkey: String
    public let parsedQRCode: ParsedDriverQRCode

    public init(hexPubkey: String, parsedQRCode: ParsedDriverQRCode) {
        self.hexPubkey = hexPubkey
        self.parsedQRCode = parsedQRCode
    }
}

public struct DriverLookupDraft: Equatable {
    public var pubkeyInput: String
    public var errorMessage: String?
    public var scannedName: String?

    public init(
        pubkeyInput: String = "",
        errorMessage: String? = nil,
        scannedName: String? = nil
    ) {
        self.pubkeyInput = pubkeyInput
        self.errorMessage = errorMessage
        self.scannedName = scannedName
    }

    public mutating func updatePubkeyInput(_ newValue: String) {
        pubkeyInput = newValue
        errorMessage = nil
        scannedName = nil
    }

    @discardableResult
    public mutating func applyScannedCode(_ rawValue: String) -> ParsedDriverQRCode? {
        guard let parsed = DriverQRCodeParser.parse(rawValue) else {
            errorMessage = "QR code doesn't contain a valid Nostr public key"
            scannedName = nil
            return nil
        }

        pubkeyInput = parsed.pubkeyInput
        scannedName = parsed.scannedName
        errorMessage = nil
        return parsed
    }

    public mutating func resolveLookup() -> ResolvedDriverLookup? {
        let trimmed = pubkeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let parsed = DriverQRCodeParser.parse(trimmed) else {
            errorMessage = "Enter a valid npub, hex key, or driver share URL"
            return nil
        }

        scannedName = parsed.scannedName

        let hexPubkey: String
        if parsed.pubkeyInput.hasPrefix("npub1") {
            guard let decoded = try? NIP19.npubDecode(parsed.pubkeyInput) else {
                errorMessage = "Invalid npub format"
                return nil
            }
            hexPubkey = decoded
        } else {
            hexPubkey = parsed.pubkeyInput
        }

        errorMessage = nil
        return ResolvedDriverLookup(hexPubkey: hexPubkey, parsedQRCode: parsed)
    }
}

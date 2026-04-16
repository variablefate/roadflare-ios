import Foundation

public struct ParsedDriverQRCode: Equatable {
    public let pubkeyInput: String
    public let scannedName: String?
}

public enum DriverQRCodeParser {
    public static func parse(_ rawValue: String) -> ParsedDriverQRCode? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = parseNostrURI(trimmed) {
            return parsed
        }

        if let parsed = parseBareNpub(trimmed) {
            return parsed
        }

        if let parsed = parseHexPubkey(trimmed) {
            return parsed
        }

        return parseURLOrEmbeddedNpub(trimmed)
    }

    private static func parseNostrURI(_ value: String) -> ParsedDriverQRCode? {
        guard value.hasPrefix("nostr:") else { return nil }
        let withoutScheme = String(value.dropFirst(6))
        return parseNpubWithOptionalQuery(withoutScheme)
    }

    private static func parseBareNpub(_ value: String) -> ParsedDriverQRCode? {
        guard value.hasPrefix("npub1") else { return nil }
        return parseNpubWithOptionalQuery(value)
    }

    private static func parseNpubWithOptionalQuery(_ value: String) -> ParsedDriverQRCode? {
        let parts = value.split(separator: "?", maxSplits: 1)
        let npubPart = String(parts[0])
        guard npubPart.hasPrefix("npub1") else { return nil }

        let nameParam: String?
        if parts.count > 1 {
            nameParam = parseNameParam(String(parts[1]))
        } else {
            nameParam = nil
        }

        return ParsedDriverQRCode(pubkeyInput: npubPart, scannedName: nameParam)
    }

    private static func parseHexPubkey(_ value: String) -> ParsedDriverQRCode? {
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return ParsedDriverQRCode(pubkeyInput: value, scannedName: nil)
    }

    private static func parseURLOrEmbeddedNpub(_ value: String) -> ParsedDriverQRCode? {
        guard let npubRange = value.range(of: #"npub1[a-z0-9]{58,}"#, options: .regularExpression) else {
            return nil
        }

        let scannedName = parseName(from: value)
        return ParsedDriverQRCode(pubkeyInput: String(value[npubRange]), scannedName: scannedName)
    }

    private static func parseName(from value: String) -> String? {
        if let components = URLComponents(string: value),
           let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
           let trimmedName = trimmedNonEmpty(name)
        {
            return trimmedName
        }

        guard let queryStart = value.firstIndex(of: "?") else { return nil }
        let query = String(value[value.index(after: queryStart)...])
        return parseNameParam(query)
    }

    private static func parseNameParam(_ query: String) -> String? {
        let pairs = query.split(separator: "&")
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "name" {
                return trimmedNonEmpty(String(kv[1]).removingPercentEncoding ?? String(kv[1]))
            }
        }
        return nil
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

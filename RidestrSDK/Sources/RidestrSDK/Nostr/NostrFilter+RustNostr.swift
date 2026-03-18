import Foundation
import NostrSDK

/// Internal conversion from our NostrFilter to rust-nostr Filter.
extension NostrFilter {
    func toRustNostrFilter() throws -> Filter {
        var filter = Filter()

        if let ids {
            let eventIds = try ids.map { try EventId.parse(id: $0) }
            filter = filter.ids(ids: eventIds)
        }

        if let authors {
            let pubkeys = try authors.map { try PublicKey.parse(publicKey: $0) }
            filter = filter.authors(authors: pubkeys)
        }

        if let kinds {
            let rustKinds = kinds.map { Kind(kind: $0) }
            filter = filter.kinds(kinds: rustKinds)
        }

        if let since {
            filter = filter.since(timestamp: Timestamp.fromSecs(secs: UInt64(since)))
        }

        if let until {
            filter = filter.until(timestamp: Timestamp.fromSecs(secs: UInt64(until)))
        }

        if let limit {
            filter = filter.limit(limit: UInt64(limit))
        }

        // Tag filters: map single-character tag names to Alphabet enum
        let alphabetMap: [String: Alphabet] = [
            "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f,
            "g": .g, "h": .h, "i": .i, "j": .j, "k": .k, "l": .l,
            "m": .m, "n": .n, "o": .o, "p": .p, "q": .q, "r": .r,
            "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x,
            "y": .y, "z": .z,
        ]
        for (tagName, values) in tagFilters {
            guard let alpha = alphabetMap[tagName.lowercased()] else { continue }
            let singleLetter = SingleLetterTag.lowercase(character: alpha)
            filter = filter.customTags(tag: singleLetter, contents: values)
        }

        return filter
    }
}

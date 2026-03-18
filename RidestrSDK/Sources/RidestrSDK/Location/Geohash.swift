import Foundation

/// Geohash encoding/decoding for location privacy in the Ridestr protocol.
///
/// A geohash is a string that encodes a geographic bounding box. Shorter strings
/// represent larger areas (less precise), longer strings represent smaller areas.
public struct Geohash: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The geohash string.
    public let hash: String

    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Create a geohash from latitude/longitude at the given precision.
    public init(latitude: Double, longitude: Double, precision: Int = GeohashPrecision.ride) {
        self.hash = Self.encode(latitude: latitude, longitude: longitude, precision: precision)
    }

    /// Create a geohash from an existing hash string.
    public init(hash: String) throws {
        let lower = hash.lowercased()
        guard !lower.isEmpty else {
            throw RidestrError.invalidGeohash("Empty geohash")
        }
        for char in lower {
            guard Self.base32.contains(char) else {
                throw RidestrError.invalidGeohash("Invalid character '\(char)' in geohash")
            }
        }
        self.hash = lower
    }

    /// Center latitude of the geohash cell.
    public var latitude: Double {
        let (lat, _) = Self.decode(hash)
        return lat
    }

    /// Center longitude of the geohash cell.
    public var longitude: Double {
        let (_, lon) = Self.decode(hash)
        return lon
    }

    /// Bounding box of the geohash cell.
    public var boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        Self.decodeBounds(hash)
    }

    /// Whether a coordinate falls within this geohash cell.
    public func contains(latitude: Double, longitude: Double) -> Bool {
        let bb = boundingBox
        return latitude >= bb.minLat && latitude <= bb.maxLat
            && longitude >= bb.minLon && longitude <= bb.maxLon
    }

    /// The 8 neighboring geohash cells.
    public func neighbors() -> [Geohash] {
        let directions: [(Int, Int)] = [
            (-1, -1), (-1, 0), (-1, 1),
            (0, -1),           (0, 1),
            (1, -1),  (1, 0),  (1, 1),
        ]
        let bb = boundingBox
        let latStep = bb.maxLat - bb.minLat
        let lonStep = bb.maxLon - bb.minLon
        let centerLat = (bb.minLat + bb.maxLat) / 2
        let centerLon = (bb.minLon + bb.maxLon) / 2

        return directions.compactMap { (dLat, dLon) in
            let newLat = centerLat + Double(dLat) * latStep
            let newLon = centerLon + Double(dLon) * lonStep
            guard newLat >= -90 && newLat <= 90 && newLon >= -180 && newLon <= 180 else {
                return nil
            }
            return Geohash(latitude: newLat, longitude: newLon, precision: hash.count)
        }
    }

    public var description: String { hash }

    // MARK: - Encoding

    static func encode(latitude: Double, longitude: Double, precision: Int) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isLon = true
        var bit = 0
        var charIndex = 0
        var result = ""

        while result.count < precision {
            if isLon {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid {
                    charIndex = charIndex | (1 << (4 - bit))
                    lonRange.0 = mid
                } else {
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid {
                    charIndex = charIndex | (1 << (4 - bit))
                    latRange.0 = mid
                } else {
                    latRange.1 = mid
                }
            }
            isLon.toggle()
            bit += 1
            if bit == 5 {
                result.append(base32[charIndex])
                bit = 0
                charIndex = 0
            }
        }
        return result
    }

    // MARK: - Decoding

    static func decode(_ hash: String) -> (latitude: Double, longitude: Double) {
        let bb = decodeBounds(hash)
        return ((bb.minLat + bb.maxLat) / 2, (bb.minLon + bb.maxLon) / 2)
    }

    static func decodeBounds(_ hash: String) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isLon = true

        for char in hash.lowercased() {
            guard let idx = base32.firstIndex(of: char) else { continue }
            let charValue = base32.distance(from: base32.startIndex, to: idx)
            for bit in stride(from: 4, through: 0, by: -1) {
                if isLon {
                    let mid = (lonRange.0 + lonRange.1) / 2
                    if (charValue >> bit) & 1 == 1 {
                        lonRange.0 = mid
                    } else {
                        lonRange.1 = mid
                    }
                } else {
                    let mid = (latRange.0 + latRange.1) / 2
                    if (charValue >> bit) & 1 == 1 {
                        latRange.0 = mid
                    } else {
                        latRange.1 = mid
                    }
                }
                isLon.toggle()
            }
        }
        return (latRange.0, latRange.1, lonRange.0, lonRange.1)
    }

    // MARK: - Multi-Precision Tags

    /// Generate geohash tags at multiple precision levels (for Nostr event tags).
    /// Returns tags from minPrecision to maxPrecision, each a prefix of the full hash.
    public static func tags(
        latitude: Double,
        longitude: Double,
        minPrecision: Int = GeohashPrecision.normalSearch,
        maxPrecision: Int = GeohashPrecision.ride
    ) -> [String] {
        let full = encode(latitude: latitude, longitude: longitude, precision: maxPrecision)
        return (minPrecision...maxPrecision).map { precision in
            String(full.prefix(precision))
        }
    }
}

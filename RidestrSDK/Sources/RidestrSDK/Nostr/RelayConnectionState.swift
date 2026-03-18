import Foundation

/// Connection state for a relay.
public enum RelayConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
}

/// Status of a single relay.
public struct RelayStatus: Sendable {
    public let url: URL
    public let state: RelayConnectionState
}

/// Unique identifier for a subscription.
public struct SubscriptionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

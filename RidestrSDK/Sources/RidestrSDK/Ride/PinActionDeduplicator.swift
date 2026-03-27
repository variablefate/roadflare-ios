import Foundation

/// Tracks which driver PIN-submit actions have been processed, preventing
/// duplicate handling after app relaunch or event replay.
public struct PinActionDeduplicator: Sendable {
    public var processedKeys: Set<String>
    public var inFlightKeys: Set<String>
    public let maxCombinedSize: Int

    public init(processedKeys: Set<String> = [], maxCombinedSize: Int = 10) {
        self.processedKeys = processedKeys
        self.inFlightKeys = []
        self.maxCombinedSize = maxCombinedSize
    }

    /// Attempt to begin processing a PIN action. Returns `true` if the action
    /// is new and should be processed, `false` if it's a duplicate or the set is full.
    public mutating func beginProcessing(_ action: DriverRideAction) -> Bool {
        let fullKey = Self.actionKey(for: action)
        guard !processedKeys.contains(fullKey),
              !processedKeys.contains(Self.legacyActionKey(action.at)),
              !inFlightKeys.contains(fullKey),
              processedKeys.count + inFlightKeys.count < maxCombinedSize else { return false }
        inFlightKeys.insert(fullKey)
        return true
    }

    /// Mark a PIN action as finished. If `processed` is true, the action is recorded
    /// as completed and will be rejected by future `beginProcessing` calls.
    public mutating func finishProcessing(_ action: DriverRideAction, processed: Bool) {
        let fullKey = Self.actionKey(for: action)
        inFlightKeys.remove(fullKey)
        if processed {
            processedKeys.insert(fullKey)
        }
    }

    /// Check whether a PIN action has already been fully processed.
    public func hasProcessed(_ action: DriverRideAction) -> Bool {
        let fullKey = Self.actionKey(for: action)
        return processedKeys.contains(fullKey) ||
            processedKeys.contains(Self.legacyActionKey(action.at))
    }

    public mutating func reset() {
        processedKeys.removeAll()
        inFlightKeys.removeAll()
    }

    // MARK: - Key generation

    /// Full action key: `"pin_submit:{timestamp}:{pinEncrypted}"`.
    public static func actionKey(for action: DriverRideAction) -> String {
        "pin_submit:\(action.at):\(action.pinEncrypted ?? "")"
    }

    /// Legacy key format for backward compatibility: `"pin_submit:{timestamp}"`.
    public static func legacyActionKey(_ timestamp: Int) -> String {
        "pin_submit:\(timestamp)"
    }
}

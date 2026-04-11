import os
import RidestrSDK

/// Centralized logging for the RoadFlare app.
/// Uses os.Logger for proper system integration — shows in Console.app,
/// respects log levels, and compiles to no-ops for messages below the
/// configured level in release builds.
public enum AppLogger {
    private static let subsystem = "com.roadflare"

    public static let relay = Logger(subsystem: subsystem, category: "relay")
    public static let ride = Logger(subsystem: subsystem, category: "ride")
    public static let location = Logger(subsystem: subsystem, category: "location")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let sdk = Logger(subsystem: subsystem, category: "sdk")

    /// Wire `RidestrLogger.handler` so SDK log output surfaces through
    /// `AppLogger.sdk`. Without this, every `RidestrLogger.info/warning/error`
    /// call in the SDK is silently discarded. Must be called at app launch
    /// BEFORE any SDK code runs.
    public static func bootstrapSDKLogging() {
        RidestrLogger.handler = { level, message, _, _ in
            switch level {
            case .debug: sdk.debug("\(message)")
            case .info: sdk.info("\(message)")
            case .warning: sdk.warning("\(message)")
            case .error: sdk.error("\(message)")
            }
        }
    }
}

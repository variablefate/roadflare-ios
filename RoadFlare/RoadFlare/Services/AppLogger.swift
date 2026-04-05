import os
import RidestrSDK

/// Centralized logging for the RoadFlare app.
/// Uses os.Logger for proper system integration — shows in Console.app,
/// respects log levels, and compiles to no-ops for messages below the
/// configured level in release builds.
enum AppLogger {
    private static let subsystem = "com.roadflare"

    static let relay = Logger(subsystem: subsystem, category: "relay")
    static let ride = Logger(subsystem: subsystem, category: "ride")
    static let location = Logger(subsystem: subsystem, category: "location")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let sdk = Logger(subsystem: subsystem, category: "sdk")

    /// Wire `RidestrLogger.handler` so SDK log output surfaces through
    /// `AppLogger.sdk`. Without this, every `RidestrLogger.info/warning/error`
    /// call in the SDK is silently discarded. Must be called at app launch
    /// BEFORE any SDK code runs.
    static func bootstrapSDKLogging() {
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

import os

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
}

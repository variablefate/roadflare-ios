import Foundation

/// Log severity levels for RidestrSDK.
public enum RidestrLogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: RidestrLogLevel, rhs: RidestrLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

/// Logging abstraction for RidestrSDK.
///
/// Set `RidestrLogger.handler` in your app to route SDK log output:
/// ```swift
/// import os
///
/// let logger = Logger(subsystem: "com.roadflare", category: "SDK")
/// RidestrLogger.handler = { level, message, file, line in
///     switch level {
///     case .debug: logger.debug("\(message)")
///     case .info: logger.info("\(message)")
///     case .warning: logger.warning("\(message)")
///     case .error: logger.error("\(message)")
///     }
/// }
/// ```
public enum RidestrLogger: Sendable {
    /// Custom log handler. Set this to receive SDK log output.
    /// If nil, logs are silently discarded.
    public nonisolated(unsafe) static var handler: (@Sendable (RidestrLogLevel, String, StaticString, UInt) -> Void)?

    /// Log a message at the given level.
    public static func log(
        _ level: RidestrLogLevel,
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        handler?(level, message(), file, line)
    }

    /// Convenience: log at debug level.
    public static func debug(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        log(.debug, message(), file: file, line: line)
    }

    /// Convenience: log at info level.
    public static func info(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        log(.info, message(), file: file, line: line)
    }

    /// Convenience: log at warning level.
    public static func warning(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        log(.warning, message(), file: file, line: line)
    }

    /// Convenience: log at error level.
    public static func error(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        log(.error, message(), file: file, line: line)
    }
}

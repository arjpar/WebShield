import Foundation
import os

/// A simple, concurrency-safe logger for in-app text logs.
public actor WebShieldLogger {

    /// Keep a ring buffer or simple array for logs.
    /// Here we just append and trim to the last 1000 entries.
    private var logs: [String] = []

    /// Single shared instance (a “global” with minimal side effects).
    public static let shared = WebShieldLogger()

    /// Limit the maximum number of lines we store in memory.
    private let maxEntries = 1000

    /// Private initializer to enforce singleton usage.
    private init() {}

    // MARK: - Public API

    /// Appends a new line to the in-memory logs (and trims older entries).
    /// Also prints to the console for convenience.
    public func log(_ message: String) {
        let timestamp = Self.currentTimestamp()
        logs.append("[\(timestamp)] \(message)")

        // Keep memory usage bounded to maxEntries
        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }

        // For development convenience, also log to console
        print(message)
    }

    /// Retrieves all logged lines.
    /// - Returns: An array of all log messages in chronological order.
    public func allLogs() -> [String] {
        logs
    }

    public func clearLogs() {
        logs.removeAll()
        log("Logs cleared.") // Optionally, log the action itself
    }

    // MARK: - Specialized Logging Methods

    /// Logs a simple timestamped step message (like “Processing,” etc.).
    public func logFilterListProcessingStep(_ step: String, for listName: String) {
        self.log("\(listName): \(step)")
    }

    /// Logs the start of a refresh event with a blank line for clarity.
    public func logRefreshStart() {
        self.log("\n\nSTARTING REFRESH\n")
    }

    /// Logs general “conversion statistics,” similar to your original code.
    public func logConversionStatistics(
        totalConvertedCount: Int,
        convertedCount: Int,
        errorsCount: Int,
        overLimit: Bool,
        for listName: String
    ) {
        self.log(
            """
            Conversion statistics for \(listName):
            - Total converted count: \(totalConvertedCount)
            - Converted count: \(convertedCount)
            - Errors count: \(errorsCount)
            - Over limit: \(overLimit)
            """)
    }

    /// Logs aggregated stats across multiple lists or processes.
    public func logTotalStatistics(_ stats: TotalStats) {
        self.log(
            """
            Total conversion statistics:
            - Total converted count: \(stats.totalConvertedCount)
            - Converted count: \(stats.convertedCount)
            - Errors count: \(stats.errorsCount)
            - Lists over limit: \(stats.overLimit)
            """)
    }

    // MARK: - Helper

    /// Generates a time-only (HH:mm:ss) localized timestamp.
    private static func currentTimestamp() -> String {
        let now = Date()
        return DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium)
    }
}

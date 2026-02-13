//
//  Utils.swift
//  safari-blocker
//
//  Created by Andrey Meshkov on 29/01/2025.
//

import Foundation
import OSLog

// MARK: - Shared Logging

public enum LogLevel: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    public var displayName: String {
        rawValue.capitalized
    }

    public var icon: String {
        switch self {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .notice: return "bell"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        case .fault: return "bolt.trianglebadge.exclamationmark"
        }
    }
}

public struct LogEntry: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: LogLevel,
        category: String,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

public extension Notification.Name {
    static let webShieldLogDidAppend = Notification.Name("WebShieldLogDidAppend")
}

public actor WebShieldLogFileStore {
    public static let shared = WebShieldLogFileStore()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxEntries = 2000
    private let maxBytes: UInt64 = 2_000_000

    private init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private var logsDirectoryURL: URL? {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value
        ) else {
            return nil
        }

        let directoryURL = appGroupURL.appendingPathComponent(
            AppGroupSubfolder.logs,
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return directoryURL
        } catch {
            return nil
        }
    }

    private var logFileURL: URL? {
        logsDirectoryURL?.appendingPathComponent("webshield.log")
    }

    public func append(_ entry: LogEntry) {
        guard let url = logFileURL else { return }
        guard let data = try? encoder.encode(entry) else { return }

        var lineData = data
        lineData.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                try? handle.close()
            }
        } else {
            try? lineData.write(to: url, options: .atomic)
        }

        trimIfNeeded(at: url)
    }

    public func readEntries(
        limit: Int? = nil,
        categories: Set<String>? = nil
    ) -> [LogEntry] {
        guard let url = logFileURL else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let contents = String(data: data, encoding: .utf8) else { return [] }

        var entries: [LogEntry] = []
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        entries.reserveCapacity(lines.count)

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                let entry = try? decoder.decode(LogEntry.self, from: lineData)
            else { continue }

            if let categories, !categories.contains(entry.category) {
                continue
            }

            entries.append(entry)
        }

        if let limit, entries.count > limit {
            return Array(entries.suffix(limit))
        }

        return entries
    }

    public func clearAll() {
        guard let url = logFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func clear(categories: Set<String>) {
        guard let url = logFileURL else { return }
        let entries = readEntries().filter { !categories.contains($0.category) }
        rewrite(entries, to: url)
    }

    private func rewrite(_ entries: [LogEntry], to url: URL) {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let lines = entries.compactMap { try? encoder.encode($0) }
        var data = Data()
        data.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })

        for line in lines {
            data.append(line)
            data.append(0x0A)
        }

        try? data.write(to: url, options: .atomic)
    }

    private func trimIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return }

        if size.uint64Value <= maxBytes {
            return
        }

        let entries = readEntries(limit: maxEntries)
        rewrite(entries, to: url)
    }
}

public struct WebShieldLogger: Sendable {
    public static let shared = WebShieldLogger()
    private let subsystem = "WebShield"

    public func log(
        _ message: String,
        level: LogLevel = .info,
        category: String = "General"
    ) {
        let osLogger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug:
            osLogger.debug("\(message)")
        case .info:
            osLogger.info("\(message)")
        case .notice:
            osLogger.notice("\(message)")
        case .warning:
            osLogger.warning("\(message)")
        case .error:
            osLogger.error("\(message)")
        case .fault:
            osLogger.fault("\(message)")
        }

        let entry = LogEntry(
            date: Date(),
            level: level,
            category: category,
            message: message
        )

        NotificationCenter.default.post(
            name: .webShieldLogDidAppend,
            object: entry
        )

        Task {
            await WebShieldLogFileStore.shared.append(entry)
        }
    }

    public func debug(_ message: String, category: String = "General") {
        log(message, level: .debug, category: category)
    }

    public func info(_ message: String, category: String = "General") {
        log(message, level: .info, category: category)
    }

    public func notice(_ message: String, category: String = "General") {
        log(message, level: .notice, category: category)
    }

    public func warning(_ message: String, category: String = "General") {
        log(message, level: .warning, category: category)
    }

    public func error(_ message: String, category: String = "General") {
        log(message, level: .error, category: category)
    }

    public func fault(_ message: String, category: String = "General") {
        log(message, level: .fault, category: category)
    }
}

// MARK: - Performance Measurement

/// Measures the execution time of a code block and logs the result.
///
/// - Parameters:
///   - label: A descriptive label for the operation being measured.
///   - category: Optional logging category (defaults to "Performance").
///   - block: The code block to measure.
/// - Returns: The result of the executed block.
func measure<T>(label: String, category: String = "Performance", block: () -> T) -> T {
    let start = DispatchTime.now()

    let result = block()

    let end = DispatchTime.now()
    let elapsedNanoseconds = end.uptimeNanoseconds - start.uptimeNanoseconds
    let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000

    let formattedTime = String(format: "%.3f", elapsedMilliseconds)
    WebShieldLogger.shared.debug(
        "[\(label)] completed in \(formattedTime) ms",
        category: category
    )

    return result
}

/// Measures the execution time of an async code block and logs the result.
///
/// - Parameters:
///   - label: A descriptive label for the operation being measured.
///   - category: Optional logging category (defaults to "Performance").
///   - block: The async code block to measure.
/// - Returns: The result of the executed block.
func measureAsync<T>(label: String, category: String = "Performance", block: () async throws -> T) async rethrows -> T {
    let start = DispatchTime.now()

    let result = try await block()

    let end = DispatchTime.now()
    let elapsedNanoseconds = end.uptimeNanoseconds - start.uptimeNanoseconds
    let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000

    let formattedTime = String(format: "%.3f", elapsedMilliseconds)
    WebShieldLogger.shared.debug(
        "[\(label)] completed in \(formattedTime) ms",
        category: category
    )

    return result
}

// MARK: - Formatting Utilities

/// Format bytes as human-readable string (KB, MB, etc.)
public func formatBytes(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

/// Format bytes as human-readable string (KB, MB, etc.)
public func formatBytes(_ bytes: UInt64) -> String {
    formatBytes(Int(bytes))
}

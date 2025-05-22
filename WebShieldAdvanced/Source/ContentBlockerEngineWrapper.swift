// ContentBlockerEngineWrapper.swift
import ContentBlockerEngine
import CryptoKit
import Foundation
import OSLog

// Protocol defining engine behavior
protocol EngineHandling {
    func getBlockingData(for url: URL) throws -> String
    func getCurrentRulesData() throws -> String
}

// Protocol for rules update notification
protocol RulesUpdateNotifying {
    var onRulesUpdated: ((String) -> Void)? { get set }
}

// MARK: - ContentBlockerEngineWrapper
final class ContentBlockerEngineWrapper: EngineHandling, RulesUpdateNotifying {
    private let jsonURL: URL
    private let logger = Logger(subsystem: "dev.arjuna.WebShield", category: "Engine")
    private var engine: ContentBlockerEngine?
    private var lastHash: String?
    private var cachedJSONString: String?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32?

    // Rules update notification callback
    var onRulesUpdated: ((String) -> Void)?

    init(appGroupID: String) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            throw EngineError.appGroupNotFound(appGroupID)
        }

        self.jsonURL = containerURL.appendingPathComponent("advancedBlocking.json")

        // Inline file existence check instead of calling actor-isolated method
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw EngineError.fileNotFound(jsonURL)
        }

        // Set up file monitoring
        setupFileMonitoring()
    }

    deinit {
        stopFileMonitoring()
    }

    private func setupFileMonitoring() {
        // Get file descriptor for monitoring
        fileDescriptor = open(jsonURL.path, O_EVTONLY)
        guard let fd = fileDescriptor else {
            logger.error("Failed to open file for monitoring")
            return
        }

        // Create dispatch source for file monitoring
        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global()
        )

        fileMonitor?.setEventHandler { [weak self] in
            self?.handleFileChange()
        }

        fileMonitor?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor {
                close(fd)
            }
        }

        fileMonitor?.resume()
    }

    private func stopFileMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
        if let fd = fileDescriptor {
            close(fd)
            fileDescriptor = nil
        }
    }

    private func handleFileChange() {
        do {
            let data = try Data(contentsOf: jsonURL, options: .mappedIfSafe)
            let currentHash = SHA256.hash(data: data).hexString

            if lastHash != currentHash {
                // File has changed, update the engine and cache
                let jsonString = String(decoding: data, as: UTF8.self)
                cachedJSONString = jsonString
                engine = try ContentBlockerEngine(jsonString)
                lastHash = currentHash

                // Notify about the update
                onRulesUpdated?(jsonString)
            }
        } catch {
            logger.error("Error handling file change: \(error)")
        }
    }

    func getBlockingData(for url: URL) throws -> String {
        try reloadIfNeeded()
        return try engine?.getData(url: url) ?? ""
    }

    func getCurrentRulesData() throws -> String {
        if let cached = cachedJSONString {
            return cached
        }

        let data = try Data(contentsOf: jsonURL, options: .mappedIfSafe)
        let jsonString = String(decoding: data, as: UTF8.self)
        cachedJSONString = jsonString
        return jsonString
    }

    func makeChunkedReader() throws -> ChunkFileReader {
        try ChunkFileReader(fileURL: jsonURL)
    }

    private func reloadIfNeeded() throws {
        let data = try Data(contentsOf: jsonURL, options: .mappedIfSafe)
        let currentHash = SHA256.hash(data: data).hexString

        if cachedJSONString == nil || lastHash != currentHash || engine == nil {
            let jsonString = String(decoding: data, as: UTF8.self)
            cachedJSONString = jsonString
            engine = try ContentBlockerEngine(jsonString)
            lastHash = currentHash
        } else {
            logger.info("Using cached JSON data")
        }
    }

    private func validateFileExists() throws {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw EngineError.fileNotFound(jsonURL)
        }
    }

    enum EngineError: Error {
        case appGroupNotFound(String)
        case fileNotFound(URL)
        case engineInitialization(Error)
    }
}

// Extension to convert SHA256 hash to hex string
extension SHA256.Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

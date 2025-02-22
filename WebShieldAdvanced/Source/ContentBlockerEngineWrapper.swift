// ContentBlockerEngineWrapper.swift
import ContentBlockerEngine
import Foundation
import OSLog

// MARK: - ContentBlockerEngineWrapper
actor ContentBlockerEngineWrapper {
    private let jsonURL: URL
    private let logger = Logger(subsystem: "dev.arjuna.WebShield", category: "Engine")
    private var engine: ContentBlockerEngine?
    private var lastModified: Date?
    // Cached raw JSON string, so we don’t have to re-read the file.
    private var cachedJSONString: String?
    static let shared = try? ContentBlockerEngineWrapper(appGroupID: "group.dev.arjuna.WebShield")

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
    }

    func getBlockingData(for url: URL) async throws -> String {
        try await reloadIfNeeded()
        //        try await loadEngine()
        return try engine?.getData(url: url) ?? ""
    }

    func makeChunkedReader() throws -> ChunkFileReader {
        try ChunkFileReader(fileURL: jsonURL)
    }

    private func reloadIfNeeded() async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: jsonURL.path)
        guard let modified = attrs[.modificationDate] as? Date else { return }

        if cachedJSONString == nil || lastModified != modified || engine == nil {
            try await loadEngine()
            lastModified = modified
        } else {
            logger.info("Using cached JSON data")
        }
    }

    private func loadEngine() async throws {
        let data = try Data(contentsOf: jsonURL, options: .mappedIfSafe)
        // If your JSON file is minified, this is still one complete object.
        let jsonString = String(decoding: data, as: UTF8.self)

        // Cache the string so subsequent calls don’t need to re-read the file.
        cachedJSONString = jsonString

        engine = try ContentBlockerEngine(jsonString)
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

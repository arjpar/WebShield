//
//  ContentBlockerService.swift
//  safari-blocker
//
//  Created by Andrey Meshkov on 10/12/2024.
//

internal import adblock_rust_swift
import CryptoKit
import Foundation
import SafariServices
internal import ZIPFoundation

/// ContentBlockerService provides functionality to convert AdGuard rules to Safari content blocking format
/// and manage content blocker extensions.
public enum ContentBlockerService {
    private static let logger = WebShieldLogger.shared
    private static let logCategory = "ContentBlocker"

    /// Safari requires at least one valid rule - this dummy rule matches a non-existent domain
    /// and effectively does nothing, but satisfies Safari's requirement
    private static let emptyBlockerJSON =
        """
        [{"trigger":{"url-filter":".*","if-domain":["example.invalid"]},"action":{"type":"ignore-previous-rules"}}]
        """

    public struct FilterConversionResult: Sendable {
        /// Count of all source rules in the filter list (network + cosmetic +
        /// scriptlet + procedural + CSP + exception). Every one of these rules
        /// is in effect: network rules feed Safari's content blocker JSON,
        /// while cosmetic / scriptlet / procedural / CSP rules feed the
        /// adblock-rust engine snapshot consumed by the web extension.
        public let totalSourceRuleCount: Int

        /// Subset of `totalSourceRuleCount` that landed in Safari's content
        /// blocker JSON. Always ≤ totalSourceRuleCount because Safari's schema
        /// can't represent cosmetic / scriptlet / CSP / etc. rules.
        public let safariRulesCount: Int

        public let advancedRulesText: String?
        public let truncated: Bool

        public init(
            totalSourceRuleCount: Int,
            safariRulesCount: Int,
            advancedRulesText: String?,
            truncated: Bool = false
        ) {
            self.totalSourceRuleCount = totalSourceRuleCount
            self.safariRulesCount = safariRulesCount
            self.advancedRulesText = advancedRulesText
            self.truncated = truncated
        }
    }

    struct AdvancedEngineMetadata: Codable, Equatable {
        let engineFormatVersion: Int
        let rulesHash: String
        let engineTimestamp: Int64
        let rulesCount: Int
    }

    struct AdvancedBlockingEngineSnapshot {
        let engine: AdblockEngine
        let metadata: AdvancedEngineMetadata
    }

    private struct ConversionResult {
        let safariRulesJSON: String
        let advancedRulesText: String?
        let totalSourceRuleCount: Int
        let safariRulesCount: Int
        let truncated: Bool
    }

    // MARK: - Directory Structure Setup

    /// Ensures required app group subdirectories exist.
    /// Idempotent - safe to call multiple times.
    ///
    /// - Parameter groupIdentifier: The app group identifier for accessing the shared container.
    /// - Returns: true if all directories exist or were created successfully, false otherwise.
    @discardableResult
    public static func ensureDirectoryStructure(groupIdentifier: String) -> Bool {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            logger.error(
                "Failed to access App Group container for directory setup",
                category: logCategory
            )
            return false
        }

        let requiredDirectories = [
            AppGroupSubfolder.blockListRules,
            AppGroupSubfolder.filterLists,
            AppGroupSubfolder.logs,
        ]

        for subfolder in requiredDirectories {
            let directoryURL = appGroupURL.appendingPathComponent(
                subfolder,
                isDirectory: true
            )
            guard ensureSubdirectoryExists(at: directoryURL) else {
                return false
            }
        }

        return true
    }

    @discardableResult
    private static func ensureSubdirectoryExists(at directoryURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ) {
            if isDirectory.boolValue {
                return true
            }
            logger.error(
                "File exists at expected directory path: \(directoryURL.path)",
                category: logCategory
            )
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.info(
                "Created app group directory: \(directoryURL.lastPathComponent)",
                category: logCategory
            )
            return true
        } catch {
            logger.error(
                "Failed to create directory \(directoryURL.lastPathComponent): \(error.localizedDescription)",
                category: logCategory
            )
            return false
        }
    }

    /// Reads the default filter file contents from the main bundle.
    ///
    /// - Returns: The contents of the default filter list or an error message if the file cannot be read.
    public static func readDefaultFilterList() -> String {
        do {
            if let filePath = Bundle.main.url(
                forResource: "filter",
                withExtension: "txt"
            ) {
                return try String(contentsOf: filePath, encoding: .utf8)
            }

            return "Not found the default filter file"
        } catch {
            return "Failed to read the filter file: \(error)"
        }
    }

    /// Converts AdGuard rules and exports them as a ZIP archive.
    ///
    /// - Parameters:
    ///   - rules: AdGuard syntax rules to be converted.
    /// - Returns: Data object containing a ZIP archive with Safari content blocker JSON and advanced rules,
    ///           or nil if the archive creation fails.
    public static func exportConversionResult(rules: String) -> Data? {
        let result = convertRules(rules: rules)

        // We'll use a variable so we can modify the JSON string
        var safariRulesJSON = result.safariRulesJSON
        let advancedRulesText = result.advancedRulesText

        // Attempt to pretty-print the JSON
        if let data = safariRulesJSON.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted]
            ),
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
            safariRulesJSON = prettyString
        }

        // Pass the newly formatted JSON string to the ZIP creation
        return createZipArchive(
            safariRulesJSON: safariRulesJSON,
            advancedRulesText: advancedRulesText
        )
    }

    /// Reloads the Safari content blocker extension with the specified identifier.
    ///
    /// - Parameters:
    ///   - identifier: Bundle ID of the content blocker extension to reload.
    /// - Returns: A Result indicating success or containing an error if the reload failed.
    public static func reloadContentBlocker(
        withIdentifier identifier: String
    ) -> Result<Void, Error> {
        logger.info(
            "Reloading content blocker: \(identifier)",
            category: logCategory
        )

        let result = measure(
            label: "Reload \(identifier)",
            category: logCategory
        ) {
            reloadContentBlockerSynchronously(withIdentifier: identifier)
        }

        switch result {
        case .success:
            logger.info(
                "Content blocker reloaded successfully: \(identifier)",
                category: logCategory
            )
        case .failure(let error):
            // WKErrorDomain error 6 is a common error when the content blocker
            // cannot access the blocker list file.
            let errorCode = (error as NSError).code
            let errorDomain = (error as NSError).domain
            if errorDomain == "WKErrorDomain" && errorCode == 6 {
                logger.error(
                    "Failed to reload \(identifier): blocker list file not accessible (WKError 6)",
                    category: logCategory
                )
            } else {
                logger.error(
                    "Failed to reload \(identifier): \(errorDomain) code \(errorCode) - \(error.localizedDescription)",
                    category: logCategory
                )
            }
        }

        return result
    }

    /// Saves the provided JSON content to the content blocker file in the shared container
    /// without attempting to convert the rules.
    ///
    /// - Parameters:
    ///   - jsonRules: Safari content blocker JSON contents in proper format.
    ///   - groupIdentifier: Group ID to use for the shared container where
    ///                      the file will be saved.
    ///   - rulesFilename: The name of the file to save the rules to.
    /// - Returns: The number of entries in the JSON array.
    public static func saveContentBlocker(
        jsonRules: String,
        groupIdentifier: String,
        rulesFilename: String
    ) -> Int {
        logger.info(
            "Writing pre-converted Safari rules JSON to \(rulesFilename)",
            category: logCategory
        )

        do {
            guard let jsonData = jsonRules.data(using: .utf8) else {
                // In theory, this cannot happen.
                fatalError("Failed to convert string to bytes")
            }
            let rules =
                try JSONSerialization.jsonObject(with: jsonData, options: [])
                as? [[String: Any]]

            measure(label: "Saving file") {
                saveBlockerListFile(
                    contents: jsonRules,
                    groupIdentifier: groupIdentifier,
                    filename: rulesFilename
                )
            }

            return rules?.count ?? 0
        } catch {
            logger.error(
                "Failed to decode content blocker JSON: \(error.localizedDescription)",
                category: logCategory
            )
        }

        return 0
    }

    /// Rebuilds and saves the advanced blocking engine for the web extension.
    ///
    /// - Parameters:
    ///   - groupIdentifier: Group ID to use for the shared container.
    ///   - advancedRules: Advanced rules to compile for the engine.
    public static func rebuildAdvancedBlockingEngine(
        groupIdentifier: String,
        advancedRules: String = ""
    ) {
        let normalizedRules = normalizeFilterSetText(advancedRules)
        let ruleCount = countFilterRules(in: normalizedRules)
        let inputSize = formatBytes(advancedRules.utf8.count)

        logger.debug(
            "Compiling adblock-rust engine snapshot: \(ruleCount) rules (\(inputSize))",
            category: logCategory
        )

        measure(label: "Compile adblock-rust engine snapshot", category: logCategory) {
            guard
                let engineURL = advancedEngineFileURL(
                    groupIdentifier: groupIdentifier
                ),
                let metadataURL = advancedEngineMetadataFileURL(
                    groupIdentifier: groupIdentifier
                )
            else {
                logger.error(
                    "Failed to access App Group container for advanced engine",
                    category: logCategory
                )
                return
            }

            let rulesHash = computeRulesHash(normalizedRules)
            if let existingMetadata = readAdvancedEngineMetadata(
                from: metadataURL
            ),
                existingMetadata.rulesHash == rulesHash,
                FileManager.default.fileExists(atPath: engineURL.path)
            {
                logger.info(
                    "adblock-rust engine snapshot unchanged (hash match): \(ruleCount) rules, reusing cached serialization",
                    category: logCategory
                )
                return
            }

            do {
                let engine = AdblockEngine(filterSet: normalizedRules)
                engine.useDefaultResources()

                try FileManager.default.createDirectory(
                    at: engineURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try engine.serializedData().write(to: engineURL, options: .atomic)

                let metadata = AdvancedEngineMetadata(
                    engineFormatVersion: 2,
                    rulesHash: rulesHash,
                    engineTimestamp: currentEngineTimestamp(),
                    rulesCount: ruleCount
                )
                let metadataData = try JSONEncoder().encode(metadata)
                try metadataData.write(to: metadataURL, options: .atomic)
                advancedEngineCache.invalidate()

                logger.info(
                    "Serialized adblock-rust engine snapshot to disk: \(ruleCount) rules",
                    category: logCategory
                )
            } catch {
                logger.error(
                    "adblock-rust engine snapshot failed: \(error.localizedDescription)",
                    category: logCategory
                )
            }
        }
    }

    /// Converts AdGuard rules to Safari content blocker format and saves them to the shared container.
    ///
    /// - Parameters:
    ///   - rules: AdGuard rules to be converted.
    ///   - groupIdentifier: Group ID to use for the shared container where
    ///                      the file will be saved.
    ///   - rulesFilename: The name of the file to save the rules to.
    /// - Returns: The total source rule count (network + cosmetic + scriptlet
    ///   + procedural + CSP + exception). The Safari-only subset is available
    ///   via `convertFilterWithAdvancedRules(...).safariRulesCount`.
    public static func convertFilter(
        rules: String,
        groupIdentifier: String,
        rulesFilename: String
    ) -> Int {
        convertFilterWithAdvancedRules(
            rules: rules,
            groupIdentifier: groupIdentifier,
            rulesFilename: rulesFilename,
            buildAdvancedEngine: true
        ).totalSourceRuleCount
    }

    /// Extracts advanced rules text from AdGuard rules.
    ///
    /// - Parameter rules: AdGuard rules to parse.
    /// - Returns: Advanced rules text extracted from the input rules.
    public static func extractAdvancedRules(from rules: String) -> String {
        normalizeFilterSetText(rules)
    }

    /// Converts AdGuard rules and returns the advanced rules text for engine merging.
    /// Uses SHA256 hash-based caching to skip conversion when input rules haven't changed.
    ///
    /// - Parameters:
    ///   - rules: AdGuard rules to be converted.
    ///   - groupIdentifier: Group ID to use for the shared container where
    ///                      the file will be saved.
    ///   - rulesFilename: The name of the file to save the rules to.
    ///   - buildAdvancedEngine: Whether to rebuild the advanced blocking engine.
    /// - Returns: The conversion result including total rule count and advanced rules.
    public static func convertFilterWithAdvancedRules(
        rules: String,
        groupIdentifier: String,
        rulesFilename: String,
        buildAdvancedEngine: Bool,
        ruleLimit: Int = ContentBlockerRuleLimit.currentPlatformLimit
    ) -> FilterConversionResult {
        // Compute SHA256 hash of input rules for cache lookup
        let rulesHash = measure(
            label: "Compute rules hash",
            category: logCategory
        ) {
            computeRulesHash("rule-limit:\(ruleLimit)\n\(rules)")
        }

        // Check cache for existing conversion
        let cacheResult = checkCache(
            rulesHash: rulesHash,
            groupIdentifier: groupIdentifier,
            rulesFilename: rulesFilename
        )

        let baseJSON: String
        let baseRuleCount: Int
        let advancedRulesText: String?
        var conversionWasTruncated = false

        if cacheResult.isHit, let cachedBaseJSON = cacheResult.baseJSON {
            // Cache hit - use cached base JSON
            baseJSON = cachedBaseJSON
            baseRuleCount = cacheResult.baseRuleCount
            advancedRulesText = cacheResult.advancedRulesText

            logger.info(
                "Using cached conversion for \(rulesFilename): \(baseRuleCount) rules",
                category: logCategory
            )
        } else {
            // Cache miss - run full conversion
            let result = convertRules(rules: rules, ruleLimit: ruleLimit)
            baseJSON = result.safariRulesJSON
            baseRuleCount = result.safariRulesCount
            advancedRulesText = result.advancedRulesText
            conversionWasTruncated = result.truncated

            if result.truncated {
                logger.error(
                    "Not caching truncated conversion output for \(rulesFilename)",
                    category: logCategory
                )
            } else {
                // Save to cache for future use
                saveToCache(
                    baseJSON: baseJSON,
                    advancedRulesText: advancedRulesText,
                    rulesHash: rulesHash,
                    groupIdentifier: groupIdentifier,
                    rulesFilename: rulesFilename
                )
            }
        }

        // Inject whitelist rules for whitelisted domains
        let whitelistedDomains = WhitelistManager.shared.whitelistedDomains
        var finalJSON = injectWhitelistRules(
            json: baseJSON,
            whitelistedDomains: whitelistedDomains
        )

        if countRulesInJSON(finalJSON) == 0 {
            finalJSON = emptyBlockerJSON
        }

        measure(label: "Saving content blocking rules file") {
            saveBlockerListFile(
                contents: finalJSON,
                groupIdentifier: groupIdentifier,
                filename: rulesFilename
            )
        }

        if buildAdvancedEngine {
            rebuildAdvancedBlockingEngine(
                groupIdentifier: groupIdentifier,
                advancedRules: advancedRulesText ?? ""
            )
        }

        // Count rules for accurate reporting:
        // - safariRulesCount = rules adblock-rust converted into Safari content
        //   blocker JSON (network-blocking subset only).
        // - totalSourceRuleCount = every rule in the source filter set; the
        //   non-Safari subset (cosmetic / scriptlet / procedural / CSP /
        //   exception) is applied by the web extension's adblock-rust engine
        //   snapshot, so all of these rules are in effect.
        let finalRuleCount = countRulesInJSON(finalJSON)
        let totalSourceRuleCount = advancedRulesText.map {
            countFilterRules(in: $0)
        } ?? 0

        return FilterConversionResult(
            totalSourceRuleCount: totalSourceRuleCount,
            safariRulesCount: finalRuleCount,
            advancedRulesText: advancedRulesText,
            truncated: conversionWasTruncated || finalRuleCount > ruleLimit
        )
    }

    /// Builds a whole-filter distribution and preflights each blocker input
    /// against the real Safari conversion limit before callers save files.
    public static func validatedRuleDistribution(
        _ filters: [FilterRuleContent],
        loadBalancer: LoadBalancer = .shared,
        ruleLimit: Int = ContentBlockerRuleLimit.currentPlatformLimit,
        whitelistRuleReserve: Int = WhitelistManager.shared.whitelistedDomains
            .count,
        conversionPreflight: ((String, Int) -> FilterConversionResult)? = nil
    ) async throws -> [ContentBlockerCategory: RuleShardAssignment] {
        let distribution = try await loadBalancer.distributeRuleContent(
            filters,
            ruleLimit: ruleLimit,
            whitelistRuleReserve: whitelistRuleReserve
        )
        let preflight =
            conversionPreflight
            ?? { rules, ruleLimit in
                let conversion = convertRules(
                    rules: rules,
                    ruleLimit: ruleLimit
                )
                return FilterConversionResult(
                    totalSourceRuleCount: conversion.totalSourceRuleCount,
                    safariRulesCount: conversion.safariRulesCount,
                    advancedRulesText: conversion.advancedRulesText,
                    truncated: conversion.truncated
                )
            }

        let exceedingBlockers: [ContentBlockerCategory] =
            distribution.values.compactMap { assignment in
                guard !assignment.isEmpty else { return nil }
                let conversion = preflight(assignment.rulesText, ruleLimit)
                let exceedsLimit = conversion.truncated
                    || conversion.safariRulesCount + whitelistRuleReserve
                        > ruleLimit

                if exceedsLimit {
                    logger.error(
                        "Rule distribution preflight exceeded \(ruleLimit) rules for blocker\(assignment.blocker.rawValue): \(conversion.safariRulesCount) converted rules + \(whitelistRuleReserve) whitelist rules",
                        category: logCategory
                    )
                }

                return exceedsLimit ? assignment.blocker : nil
            }

        guard exceedingBlockers.isEmpty else {
            throw RuleShardingError.conversionValidationExceeded(
                ruleLimit: ruleLimit,
                blockers: exceedingBlockers
            )
        }

        return distribution
    }

    /// Fast update for whitelist changes only - skips full filter conversion.
    /// Reads cached base JSON and re-injects whitelist rules without full conversion.
    ///
    /// - Parameters:
    ///   - groupIdentifier: Group ID to use for the shared container.
    ///   - rulesFilename: Target filename for the rules file.
    /// - Returns: The number of Safari content blocker rules after update.
    public static func fastUpdateWhitelist(
        groupIdentifier: String,
        rulesFilename: String
    ) -> Int {
        let whitelistedDomains = WhitelistManager.shared.whitelistedDomains

        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else {
            logger.error(
                "Failed to access App Group container for whitelist update",
                category: logCategory
            )
            return 0
        }

        // Prefer cached base JSON (clean, without whitelist rules)
        let baseURL = containerURL.appendingPathComponent(
            baseCacheFilename(for: rulesFilename)
        )

        if FileManager.default.fileExists(atPath: baseURL.path),
            let baseJSON = try? String(contentsOf: baseURL, encoding: .utf8)
        {
            // Use cached base JSON
            var finalJSON = injectWhitelistRules(
                json: baseJSON,
                whitelistedDomains: whitelistedDomains
            )

            // Check if result would be empty - Safari requires at least one rule
            var finalRuleCount = countRulesInJSON(finalJSON)
            if finalRuleCount == 0 {
                finalJSON = emptyBlockerJSON
                finalRuleCount = 1
            }

            measure(label: "Fast updating whitelist rules in \(rulesFilename)")
            {
                saveBlockerListFile(
                    contents: finalJSON,
                    groupIdentifier: groupIdentifier,
                    filename: rulesFilename
                )
            }

            let baseCount = countRulesInJSON(baseJSON)

            logger.info(
                "Fast updated \(rulesFilename) with \(finalRuleCount) rules for \(whitelistedDomains.count) whitelisted domains (from cache)",
                category: logCategory
            )

            return baseCount + whitelistedDomains.count
        }

        // Fallback: Try existing final file (legacy path or migration)
        let fileURL = containerURL.appendingPathComponent(rulesFilename)

        guard FileManager.default.fileExists(atPath: fileURL.path),
            let existingJSON = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            logger.info(
                "No existing file found for whitelist update: \(rulesFilename)",
                category: logCategory
            )
            return 0
        }

        // Remove existing whitelist rules and inject new ones
        let baseJSON = removeWhitelistRules(json: existingJSON)
        var finalJSON = injectWhitelistRules(
            json: baseJSON,
            whitelistedDomains: whitelistedDomains
        )

        // Check if result would be empty - Safari requires at least one rule
        var finalRuleCount = countRulesInJSON(finalJSON)
        if finalRuleCount == 0 {
            finalJSON = emptyBlockerJSON
            finalRuleCount = 1
        }

        // Save derived base JSON for future fast updates
        saveBlockerListFile(
            contents: baseJSON,
            groupIdentifier: groupIdentifier,
            filename: baseCacheFilename(for: rulesFilename)
        )

        measure(label: "Fast updating whitelist rules in \(rulesFilename)") {
            saveBlockerListFile(
                contents: finalJSON,
                groupIdentifier: groupIdentifier,
                filename: rulesFilename
            )
        }

        logger.info(
            "Fast updated \(rulesFilename) with \(finalRuleCount) rules for \(whitelistedDomains.count) whitelisted domains",
            category: logCategory
        )

        return finalRuleCount
    }
}

// MARK: - Whitelist Functions

extension ContentBlockerService {
    /// Injects Safari content blocker ignore-previous-rules for whitelisted domains.
    /// This uses Safari's native ignore-previous-rules action to whitelist domains.
    ///
    /// - Parameters:
    ///   - json: Existing Safari content blocker JSON string.
    ///   - whitelistedDomains: Array of domain hostnames to whitelist.
    /// - Returns: Modified JSON string with whitelist rules injected.
    private static func injectWhitelistRules(
        json: String,
        whitelistedDomains: [String]
    ) -> String {
        guard !whitelistedDomains.isEmpty else { return json }

        do {
            // Parse existing JSON
            guard let jsonData = json.data(using: .utf8),
                let existingRules = try JSONSerialization.jsonObject(
                    with: jsonData
                )
                    as? [[String: Any]]
            else {
                logger.error(
                    "Failed to parse existing content blocker JSON for whitelist injection",
                    category: logCategory
                )
                return json
            }

            var modifiedRules = existingRules

            // Add ignore-previous-rules for each whitelisted domain
            // This rule tells Safari to ignore all previous blocking rules for the specified domains
            // Using wBlock's simple approach: no resource-type restriction so ALL requests are whitelisted
            for domain in whitelistedDomains {
                let ignoreRule: [String: Any] = [
                    "action": [
                        "type": "ignore-previous-rules"
                    ],
                    "trigger": [
                        "url-filter": ".*",
                        // Include both domain and all subdomains
                        "if-domain": [domain, "*." + domain],
                    ],
                ]
                modifiedRules.append(ignoreRule)
            }

            // Convert back to JSON
            let modifiedJsonData = try JSONSerialization.data(
                withJSONObject: modifiedRules,
                options: []
            )
            if let modifiedJsonString = String(
                data: modifiedJsonData,
                encoding: .utf8
            ) {
                logger.info(
                    "Successfully injected ignore-previous-rules for \(whitelistedDomains.count) whitelisted domains",
                    category: logCategory
                )
                return modifiedJsonString
            }
        } catch {
            logger.error(
                "Error injecting whitelist rules: \(error.localizedDescription)",
                category: logCategory
            )
        }

        return json  // Return original JSON if injection fails
    }

    /// Removes existing whitelist rules from JSON.
    /// This is used for fast updates to clean slate before re-injecting rules.
    /// Only removes rules that match our specific whitelist pattern (ignore-previous-rules
    /// with url-filter ".*" and if-domain). This matches wBlock's approach.
    ///
    /// - Parameter json: Existing Safari content blocker JSON string.
    /// - Returns: JSON string with whitelist rules removed.
    private static func removeWhitelistRules(json: String) -> String {
        do {
            guard let jsonData = json.data(using: .utf8),
                let existingRules = try JSONSerialization.jsonObject(
                    with: jsonData
                )
                    as? [[String: Any]]
            else {
                logger.error(
                    "Failed to parse JSON for whitelist rules removal",
                    category: logCategory
                )
                return json
            }

            // Filter out only rules that match our specific whitelist pattern
            // We check for: action.type == "ignore-previous-rules" AND
            // trigger.url-filter == ".*" AND trigger.if-domain exists
            // Note: Legitimate ignore-previous-rules from filter converter typically have
            // more specific url-filter patterns, not ".*"
            let filteredRules = existingRules.filter { rule in
                guard let action = rule["action"] as? [String: Any],
                    let actionType = action["type"] as? String,
                    actionType == "ignore-previous-rules",
                    let trigger = rule["trigger"] as? [String: Any],
                    let urlFilter = trigger["url-filter"] as? String,
                    urlFilter == ".*",
                    trigger["if-domain"] != nil
                else {
                    return true  // Keep rules that don't match our whitelist pattern
                }
                return false  // Remove our whitelist rules
            }

            // Convert back to JSON
            let updatedData = try JSONSerialization.data(
                withJSONObject: filteredRules,
                options: []
            )
            return String(data: updatedData, encoding: .utf8) ?? json

        } catch {
            logger.error(
                "Error removing whitelist rules: \(error.localizedDescription)",
                category: logCategory
            )
            return json
        }
    }

    /// Counts the number of rules in a Safari content blocker JSON string.
    /// Uses fast binary pattern scanning for `"action":` occurrences.
    /// Each Safari content blocker rule has exactly one "action" key.
    ///
    /// - Parameter json: Safari content blocker JSON string.
    /// - Returns: Number of rules in the JSON array.
    private static func countRulesInJSON(_ json: String) -> Int {
        guard !json.isEmpty,
            let data = json.data(using: .utf8),
            data.count >= 2
        else {
            return 0
        }

        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var ruleCount = 0
            var i = 0
            let searchEnd = bytes.count - 9  // "action": is 9 bytes

            while i <= searchEnd {
                // Pattern match: "action": (9 bytes)
                if bytes[i] == 0x22  // "
                    && bytes[i + 1] == 0x61  // a
                    && bytes[i + 2] == 0x63  // c
                    && bytes[i + 3] == 0x74  // t
                    && bytes[i + 4] == 0x69  // i
                    && bytes[i + 5] == 0x6F  // o
                    && bytes[i + 6] == 0x6E  // n
                    && bytes[i + 7] == 0x22  // "
                    && bytes[i + 8] == 0x3A
                {  // :
                    ruleCount += 1
                    i += 9  // Skip past the matched pattern
                } else {
                    i += 1
                }
            }

            return ruleCount
        }
    }
}

// MARK: - Cache File Naming

extension ContentBlockerService {
    /// Returns the base filename for cached rules (without whitelist).
    /// Example: "ads.json" -> "ads.base.json"
    private static func baseCacheFilename(for rulesFilename: String) -> String {
        if rulesFilename.lowercased().hasSuffix(".json") {
            let stem = rulesFilename.dropLast(5)
            return "\(stem).base.json"
        }
        return "\(rulesFilename).base"
    }

    /// Returns the hash filename for cached rules.
    /// Example: "ads.json" -> "ads.base.json.sha256"
    private static func hashCacheFilename(for rulesFilename: String) -> String {
        "\(baseCacheFilename(for: rulesFilename)).sha256"
    }

    /// Returns the advanced rules filename for cache.
    /// Example: "ads.json" -> "ads.base.json.advanced.txt"
    private static func advancedCacheFilename(for rulesFilename: String)
        -> String
    {
        "\(baseCacheFilename(for: rulesFilename)).advanced.txt"
    }

    /// Computes SHA256 hash of input rules string.
    private static func computeRulesHash(_ rules: String) -> String {
        let digest = SHA256.hash(data: Data(rules.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Cache Operations

extension ContentBlockerService {
    /// Result of checking the conversion cache.
    private struct CacheCheckResult {
        let isHit: Bool
        let baseJSON: String?
        let baseRuleCount: Int
        let advancedRulesText: String?
    }

    /// Checks if cached conversion results exist and are valid.
    private static func checkCache(
        rulesHash: String,
        groupIdentifier: String,
        rulesFilename: String
    ) -> CacheCheckResult {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else {
            return CacheCheckResult(
                isHit: false,
                baseJSON: nil,
                baseRuleCount: 0,
                advancedRulesText: nil
            )
        }

        let hashURL = containerURL.appendingPathComponent(
            hashCacheFilename(for: rulesFilename)
        )
        let baseURL = containerURL.appendingPathComponent(
            baseCacheFilename(for: rulesFilename)
        )
        let advancedURL = containerURL.appendingPathComponent(
            advancedCacheFilename(for: rulesFilename)
        )

        // Check if hash matches and base file exists
        guard
            let cachedHash = try? String(contentsOf: hashURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            cachedHash == rulesHash,
            FileManager.default.fileExists(atPath: baseURL.path),
            let baseJSON = try? String(contentsOf: baseURL, encoding: .utf8)
        else {
            return CacheCheckResult(
                isHit: false,
                baseJSON: nil,
                baseRuleCount: 0,
                advancedRulesText: nil
            )
        }

        let baseCount = countRulesInJSON(baseJSON)

        // Read cached advanced rules (optional)
        let advancedText =
            (try? String(contentsOf: advancedURL, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        logger.info(
            "adblock-rust conversion cache hit for \(rulesFilename): \(baseCount) Safari rules (input hash match)",
            category: logCategory
        )

        return CacheCheckResult(
            isHit: true,
            baseJSON: baseJSON,
            baseRuleCount: baseCount,
            advancedRulesText: advancedText
        )
    }

    /// Saves conversion results to cache files.
    private static func saveToCache(
        baseJSON: String,
        advancedRulesText: String?,
        rulesHash: String,
        groupIdentifier: String,
        rulesFilename: String
    ) {
        saveBlockerListFile(
            contents: baseJSON,
            groupIdentifier: groupIdentifier,
            filename: baseCacheFilename(for: rulesFilename)
        )
        saveBlockerListFile(
            contents: rulesHash,
            groupIdentifier: groupIdentifier,
            filename: hashCacheFilename(for: rulesFilename)
        )
        saveBlockerListFile(
            contents: advancedRulesText ?? "",
            groupIdentifier: groupIdentifier,
            filename: advancedCacheFilename(for: rulesFilename)
        )

        logger.debug(
            "Cached adblock-rust conversion output for \(rulesFilename) (3 files: base.json + sha256 + advanced.txt)",
            category: logCategory
        )
    }
}

// MARK: - Cache Management

extension ContentBlockerService {
    /// Clears all cache files for a specific rules file.
    /// Useful for forcing a full reconversion.
    ///
    /// - Parameters:
    ///   - groupIdentifier: Group ID for the shared container.
    ///   - rulesFilename: The rules filename to clear cache for.
    public static func clearCache(
        groupIdentifier: String,
        rulesFilename: String
    ) {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else {
            return
        }

        let filesToDelete = [
            baseCacheFilename(for: rulesFilename),
            hashCacheFilename(for: rulesFilename),
            advancedCacheFilename(for: rulesFilename),
            // Legacy from prior schema; sweep so existing installs don't carry orphans.
            "\(baseCacheFilename(for: rulesFilename)).count",
        ]

        for filename in filesToDelete {
            let fileURL = containerURL.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        }

        logger.info(
            "Cleared cache files for \(rulesFilename)",
            category: logCategory
        )
    }

    /// Clears all cache files for all content blocker categories.
    ///
    /// - Parameter groupIdentifier: Group ID for the shared container.
    public static func clearAllCaches(groupIdentifier: String) {
        for category in ContentBlockerCategory.allCases {
            clearCache(
                groupIdentifier: groupIdentifier,
                rulesFilename: category.rulesPath
            )
        }

        logger.info("Cleared all content blocker caches", category: logCategory)
    }
}

// MARK: - Advanced Engine Cache

extension ContentBlockerService {
    private static let advancedEngineSubfolder = "AdvancedEngine"
    private static let advancedEngineFilename = "adblock-engine.dat"
    private static let advancedEngineMetadataFilename = "metadata.json"
    private static let advancedEngineCache = AdvancedEngineCacheStore()

    private final class AdvancedEngineCacheStore: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedFileURL: URL?
        private var cachedModificationDate: Date?
        private var cachedSnapshot: AdvancedBlockingEngineSnapshot?

        func invalidate() {
            lock.lock()
            cachedFileURL = nil
            cachedModificationDate = nil
            cachedSnapshot = nil
            lock.unlock()
        }

        func snapshot(groupIdentifier: String) -> AdvancedBlockingEngineSnapshot? {
            lock.lock()
            defer { lock.unlock() }

            guard
                let engineURL = ContentBlockerService.advancedEngineFileURL(
                    groupIdentifier: groupIdentifier
                ),
                let metadataURL = ContentBlockerService
                    .advancedEngineMetadataFileURL(
                        groupIdentifier: groupIdentifier
                    ),
                FileManager.default.fileExists(atPath: engineURL.path)
            else {
                return nil
            }

            let modificationDate = (
                try? FileManager.default.attributesOfItem(
                    atPath: engineURL.path
                )[.modificationDate]
            ) as? Date

            if cachedFileURL == engineURL,
                cachedModificationDate == modificationDate,
                let cachedSnapshot
            {
                return cachedSnapshot
            }

            guard let data = try? Data(contentsOf: engineURL) else {
                return nil
            }

            let engine = AdblockEngine(serializedData: data)
            engine.useDefaultResources()

            let metadata =
                ContentBlockerService.readAdvancedEngineMetadata(
                    from: metadataURL
                )
                ?? AdvancedEngineMetadata(
                    engineFormatVersion: 2,
                    rulesHash: "",
                    engineTimestamp: ContentBlockerService
                        .currentEngineTimestamp(),
                    rulesCount: 0
                )
            let snapshot = AdvancedBlockingEngineSnapshot(
                engine: engine,
                metadata: metadata
            )

            cachedFileURL = engineURL
            cachedModificationDate = modificationDate
            cachedSnapshot = snapshot

            return snapshot
        }
    }

    static func loadAdvancedBlockingEngine(
        groupIdentifier: String
    ) -> AdvancedBlockingEngineSnapshot? {
        advancedEngineCache.snapshot(groupIdentifier: groupIdentifier)
    }

    private static func advancedEngineDirectoryURL(
        groupIdentifier: String
    ) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        )?
        .appendingPathComponent(advancedEngineSubfolder, isDirectory: true)
    }

    private static func advancedEngineFileURL(groupIdentifier: String) -> URL?
    {
        advancedEngineDirectoryURL(groupIdentifier: groupIdentifier)?
            .appendingPathComponent(advancedEngineFilename)
    }

    private static func advancedEngineMetadataFileURL(
        groupIdentifier: String
    ) -> URL? {
        advancedEngineDirectoryURL(groupIdentifier: groupIdentifier)?
            .appendingPathComponent(advancedEngineMetadataFilename)
    }

    private static func readAdvancedEngineMetadata(
        from url: URL
    ) -> AdvancedEngineMetadata? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(AdvancedEngineMetadata.self, from: data)
    }

    private static func currentEngineTimestamp() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func normalizeFilterSetText(_ rules: String) -> String {
        rules
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Counts actual filter rules, skipping empty lines, comments (`!`), and
    /// section markers (`[`). Matches `FilterListHeaderParser.countRules` so
    /// all parts of the app report the same source rule count for a filter.
    private static func countFilterRules(in rules: String) -> Int {
        rules
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[")
            }
            .count
    }
}

// MARK: - Safari Content Blocker functions

extension ContentBlockerService {
    /// Thread-safe storage for completion results returned from concurrent callbacks.
    private final class ReloadResultStore: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error> = .success(())

        func set(_ newValue: Result<Void, Error>) {
            lock.lock()
            result = newValue
            lock.unlock()
        }

        func get() -> Result<Void, Error> {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    /// Converts AdGuard rules into the Safari content blocking rules syntax.
    ///
    /// - Parameters:
    ///   - rules: AdGuard rules to convert.
    /// - Returns: A ConversionResult containing the converted Safari rules in JSON format
    ///           and advanced rules in text format.
    private static func convertRules(
        rules: String,
        ruleLimit: Int = ContentBlockerRuleLimit.currentPlatformLimit
    ) -> ConversionResult {
        var filterRules = rules
        if !filterRules.isContiguousUTF8 {
            measure(label: "Make contiguous UTF-8", category: logCategory) {
                filterRules.makeContiguousUTF8()
            }
        }

        let normalizedRules = normalizeFilterSetText(filterRules)
        let totalSourceRuleCount = countFilterRules(in: normalizedRules)
        let inputSize = formatBytes(rules.utf8.count)

        logger.debug(
            "adblock-rust: compiling \(totalSourceRuleCount) rules (\(inputSize)) → Safari content blocker rules",
            category: logCategory
        )

        let result = measure(label: "Rule conversion", category: logCategory) {
            AdblockEngine.contentBlockerRules(
                fromFilterSet: normalizedRules,
                ruleLimit: ruleLimit
            )
        }

        let safariRuleCount = countRulesInJSON(result.json)
        let outputSize = formatBytes(result.json.utf8.count)
        let advancedRuleCount = max(0, totalSourceRuleCount - safariRuleCount)

        logger.info(
            "adblock-rust compiled \(totalSourceRuleCount) source rules → \(safariRuleCount) Safari content-blocker rules (\(outputSize)); the remaining \(advancedRuleCount) rules (cosmetic / scriptlet / procedural / CSP / etc.) are applied by the web extension's engine snapshot. \(result.unsupportedRulesCount) parsed rules were dropped as unsupported.",
            category: logCategory
        )

        if result.unsupportedRulesCount > 0 {
            logger.warning(
                "adblock-rust dropped \(result.unsupportedRulesCount) parsed filter rules during Safari conversion because they cannot be represented as content blocker rules",
                category: logCategory
            )
        }

        if result.truncated {
            logger.warning(
                "adblock-rust hit Safari's \(ruleLimit)-rule ceiling — some rules were dropped from the JSON output",
                category: logCategory
            )
        }

        return ConversionResult(
            safariRulesJSON: result.json,
            advancedRulesText: normalizedRules.isEmpty ? nil : normalizedRules,
            totalSourceRuleCount: totalSourceRuleCount,
            safariRulesCount: safariRuleCount,
            truncated: result.truncated
        )
    }

    /// Provides a synchronous wrapper over SFContentBlockerManager.reloadContentBlocker.
    ///
    /// - Parameters:
    ///   - identifier: Bundle ID of the content blocker extension to reload.
    /// - Returns: A Result indicating success or containing an error if the reload failed.
    private static func reloadContentBlockerSynchronously(
        withIdentifier identifier: String
    ) -> Result<Void, Error> {
        // Create a semaphore with an initial count of 0
        let semaphore = DispatchSemaphore(value: 0)
        let resultStore = ReloadResultStore()

        SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier)
        { error in
            let completionResult: Result<Void, Error> =
                if let error = error {
                    .failure(error)
                } else {
                    .success(())
                }
            resultStore.set(completionResult)

            // Signal the semaphore to unblock
            semaphore.signal()
        }

        // Block the thread until the semaphore is signaled
        semaphore.wait()
        return resultStore.get()
    }

    /// Saves the blocker list file contents to the shared directory specified by the group identifier.
    ///
    /// - Parameters:
    ///   - contents: String content to write to the blocker list file.
    ///   - groupIdentifier: App group identifier for accessing the shared container.
    ///   - filename: The name of the file to save (can include subdirectory path).
    private static func saveBlockerListFile(
        contents: String,
        groupIdentifier: String,
        filename: String
    ) {
        // Get the shared container URL.
        guard
            let appGroupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else {
            logger.error(
                "Failed to access App Group container for \(filename)",
                category: logCategory
            )
            return
        }

        let sharedFileURL = appGroupURL.appendingPathComponent(filename)

        // Create parent directory if needed (for files in subfolders)
        let parentDir = sharedFileURL.deletingLastPathComponent()
        logger.debug(
            "saveBlockerListFile: filename=\(filename), parentDir=\(parentDir.path), appGroupURL=\(appGroupURL.path), needsDir=\(parentDir.path != appGroupURL.path)",
            category: logCategory
        )
        if parentDir.path != appGroupURL.path {
            do {
                try FileManager.default.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.debug(
                    "Created directory: \(parentDir.path)",
                    category: logCategory
                )
            } catch {
                logger.error(
                    "Failed to create directory for \(filename): \(error.localizedDescription)",
                    category: logCategory
                )
                return
            }
        }

        do {
            guard let data = contents.data(using: .utf8) else {
                logger.error(
                    "Failed to encode \(filename) as UTF-8",
                    category: logCategory
                )
                return
            }
            try data.write(to: sharedFileURL, options: .atomic)
            logger.debug(
                "Saved \(filename) (\(formatBytes(data.count)))",
                category: logCategory
            )
        } catch {
            logger.error(
                "Failed to save \(filename): \(error.localizedDescription)",
                category: logCategory
            )
        }
    }

    /// Creates a ZIP archive containing Safari content blocker rules and advanced rules.
    ///
    /// The archive will always include "content-blocker.json" and optionally "advanced-rules.txt"
    /// if advanced rules are provided.
    ///
    /// - Parameters:
    ///   - safariRulesJSON: JSON string containing Safari content blocker rules.
    ///   - advancedRulesText: Optional text string containing advanced blocking rules.
    /// - Returns: Data object representing the ZIP archive, or nil if archive creation fails.
    private static func createZipArchive(
        safariRulesJSON: String,
        advancedRulesText: String?
    ) -> Data? {
        // 1. Prepare data from strings
        guard let contentBlockerData = safariRulesJSON.data(using: .utf8) else {
            // In theory, this cannot happen.
            fatalError("Failed to convert string to bytes")
        }
        let advancedData = advancedRulesText?.data(using: .utf8)

        do {
            // 3. Create the Archive object with ZipFoundation
            let archive = try Archive(accessMode: .create)

            // 4. Add content-blocker.json entry
            try archive.addEntry(
                with: "content-blocker.json",
                type: .file,
                uncompressedSize: Int64(contentBlockerData.count),
                bufferSize: 4
            ) { position, size -> Data in
                // This will be called until `data` is exhausted (3x in this case).
                return contentBlockerData.subdata(
                    in: Data.Index(position)..<Int(position) + size
                )
            }

            // 5. Add advanced-rules.txt if present
            if let advancedData = advancedData {
                try archive.addEntry(
                    with: "advanced-rules.txt",
                    type: .file,
                    uncompressedSize: Int64(advancedData.count),
                    bufferSize: 4
                ) { position, size -> Data in
                    // This will be called until `data` is exhausted (3x in this case).
                    return advancedData.subdata(
                        in: Data.Index(position)..<Int(position) + size
                    )
                }
            }

            // 6. Zip creation complete
            return archive.data
        } catch {
            logger.error(
                "Error while creating a ZIP archive with rules: \(error.localizedDescription)",
                category: logCategory
            )

            return nil
        }
    }
}

//
//  ContentView.swift
//  WebShield
//
// This should be split up eventually
//
//  Created by Arjun on 2026-01-09.
//

import Foundation
import SafariServices
import SwiftUI
import UniformTypeIdentifiers
import WebShieldService

// MARK: - Data Models

/// Errors that can occur during filter list operations
enum FilterListError: Error, LocalizedError {
    case downloadFailed(String)
    case conversionFailed(String)
    case reloadFailed(String)
    case invalidURL
    case duplicateURL(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message): return "Download failed: \(message)"
        case .conversionFailed(let message):
            return "Conversion failed: \(message)"
        case .reloadFailed(let message): return "Reload failed: \(message)"
        case .invalidURL:
            return "Please enter a valid URL starting with http:// or https://"
        case .duplicateURL(let url):
            return "This filter URL is already added: \(url)"
        case .emptyContent: return "The filter list appears to be empty"
        }
    }
}

/// Parses metadata from AdGuard/EasyList filter list headers
struct FilterListHeaderParser {
    /// Parses the header comments of a filter list to extract metadata
    static func parseHeader(from content: String) -> (
        version: String?, title: String?, homepage: String?,
        lastModified: String?
    ) {
        var version: String?
        var title: String?
        var homepage: String?
        var lastModified: String?

        let lines = content.components(separatedBy: .newlines)

        for line in lines.prefix(Constants.headerLinesToScan) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Stop if we hit a non-comment line (actual rules start)
            if !trimmed.isEmpty && !trimmed.hasPrefix("!")
                && !trimmed.hasPrefix("[")
            {
                break
            }

            // Parse metadata fields
            if trimmed.hasPrefix("! Version:") {
                version =
                    trimmed
                    .replacingOccurrences(of: "! Version:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("! Title:") {
                title =
                    trimmed
                    .replacingOccurrences(of: "! Title:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("! Homepage:") {
                homepage =
                    trimmed
                    .replacingOccurrences(of: "! Homepage:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("! Last modified:") {
                lastModified =
                    trimmed
                    .replacingOccurrences(of: "! Last modified:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return (version, title, homepage, lastModified)
    }

    /// Counts the number of actual rules in a filter list (excluding comments and empty lines)
    static func countRules(in content: String) -> Int {
        content.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("!")
                    && !trimmed.hasPrefix("[")
            }
            .count
    }
}

/// Persisted metadata for a filter list
struct FilterListMetadata: Codable {
    var id: String
    var version: String
    var ruleCount: Int
    var lastUpdated: Date
    var sourceRuleCount: Int
    var downloadURL: URL?
    var category: String?

    init(
        id: String,
        version: String = "N/A",
        ruleCount: Int = -1,
        lastUpdated: Date = Date(),
        sourceRuleCount: Int = 0,
        downloadURL: URL? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.version = version
        self.ruleCount = ruleCount
        self.lastUpdated = lastUpdated
        self.sourceRuleCount = sourceRuleCount
        self.downloadURL = downloadURL
        self.category = category
    }
}

// MARK: - Shared Formatters

enum Formatters {
    static let ruleCount: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

private enum DeveloperSettingsKeys {
    static let showDeveloperFilters = "showDeveloperFilters"
    static let forceManualRefreshDownloads = "forceManualRefreshDownloads"
}

/// Represents the current phase of the refresh operation
enum RefreshPhase: Equatable {
    case preparing
    case downloading(filterName: String, current: Int, total: Int)
    case converting(category: String)
    case reloading(category: String)
    case buildingEngine
    case completed(RefreshStatistics)
    case failed(String)

    var displayText: String {
        switch self {
        case .preparing:
            return "Preparing..."
        case .downloading(let name, let current, let total):
            return "Downloading \(name) (\(current)/\(total))"
        case .converting(let category):
            return "Converting and saving \(category) rules..."
        case .reloading(let category):
            return "Reloading \(category)..."
        case .buildingEngine:
            return "Building advanced engine..."
        case .completed:
            return "Complete"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    static func == (lhs: RefreshPhase, rhs: RefreshPhase) -> Bool {
        switch (lhs, rhs) {
        case (.preparing, .preparing):
            return true
        case (
            .downloading(let n1, let c1, let t1),
            .downloading(let n2, let c2, let t2)
        ):
            return n1 == n2 && c1 == c2 && t1 == t2
        case (.converting(let c1), .converting(let c2)):
            return c1 == c2
        case (.reloading(let c1), .reloading(let c2)):
            return c1 == c2
        case (.buildingEngine, .buildingEngine):
            return true
        case (.completed, .completed):
            return true
        case (.failed(let e1), .failed(let e2)):
            return e1 == e2
        default:
            return false
        }
    }
}

/// Statistics from a refresh operation
struct RefreshStatistics {
    var totalRulesConverted: Int = 0
    var categoriesProcessed: Int = 0
    var filtersDownloaded: Int = 0
    var filtersSkipped: Int = 0  // filters unchanged (304 response)
    var categoriesSkipped: Int = 0  // categories with no changes
    var conversionDuration: TimeInterval = 0
    var reloadDuration: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var errors: [String] = []

    var hasErrors: Bool { !errors.isEmpty }

    var formattedTotalDuration: String {
        formatDuration(totalDuration)
    }

    var formattedConversionDuration: String {
        formatDuration(conversionDuration)
    }

    var formattedReloadDuration: String {
        formatDuration(reloadDuration)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1f s", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
}

/// Identifiable wrapper for URL input fields
struct URLInputEntry: Identifiable {
    let id = UUID()
    var url: String = ""
}

// MARK: - Logging

private let logger = WebShieldLogger.shared

@MainActor
@Observable
final class WebShieldLogStore {
    static let shared = WebShieldLogStore()
    private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000
    private var notificationToken: NSObjectProtocol?

    private init() {
        notificationToken = NotificationCenter.default.addObserver(
            forName: .webShieldLogDidAppend,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let entry = notification.object as? LogEntry else { return }
            Task { @MainActor in
                self?.append(entry)
            }
        }
    }

    @MainActor deinit {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
    }

    func append(_ entry: LogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }

    func refreshFromDisk() async {
        let diskEntries = await WebShieldLogFileStore.shared.readEntries(
            limit: maxEntries
        )
        entries = diskEntries.sorted { $0.date > $1.date }
    }

    func clearAll() async {
        await WebShieldLogFileStore.shared.clearAll()
        entries.removeAll()
    }

    func clear(categories: Set<String>) async {
        await WebShieldLogFileStore.shared.clear(categories: categories)
        await refreshFromDisk()
    }
}

// MARK: - View Model

@MainActor
@Observable
final class FilterListViewModel {
    // MARK: - Storage Keys

    private static let enabledFiltersKey = "enabledFilterIDs"
    private static let disabledFiltersKey = "disabledFilterIDs"
    private static let filterMetadataKey = "filterListMetadata"
    private static let customFiltersKey = "customFilterLists"
    private static let totalConvertedRulesKey = "totalConvertedRules"
    private static let filterETagsKey = "filterETags"
    private static let filterLastModifiedKey = "filterLastModified"
    private static let lastAppliedFiltersByCategoryKey =
        "lastAppliedFiltersByCategory"
    private static let showDeveloperFiltersKey =
        DeveloperSettingsKeys.showDeveloperFilters
    private static let forceManualRefreshDownloadsKey =
        DeveloperSettingsKeys.forceManualRefreshDownloads

    // MARK: - Shared Resources

    private let userDefaults: UserDefaults

    /// Shared app group container URL for storing filter data
    private nonisolated static var appGroupURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value
        )
    }

    // MARK: - State

    var filterLists: [FilterList] = []
    var selectedTab: AppTab = .filters
    var isRefreshing = false
    var showEnabledOnly = false
    var showDeveloperFilters: Bool {
        get { userDefaults.bool(forKey: Self.showDeveloperFiltersKey) }
        set { userDefaults.set(newValue, forKey: Self.showDeveloperFiltersKey) }
    }
    var forceManualRefreshDownloads: Bool {
        get {
            userDefaults.bool(forKey: Self.forceManualRefreshDownloadsKey)
        }
        set {
            userDefaults.set(
                newValue,
                forKey: Self.forceManualRefreshDownloadsKey
            )
        }
    }
    var searchText: String = ""
    var refreshProgress: Double = 0
    var refreshStatusMessage: String = ""

    // Refresh modal state
    var showRefreshSheet = false
    var refreshPhase: RefreshPhase = .preparing
    var refreshStatistics = RefreshStatistics()

    // Custom filter sheet state
    var showAddCustomFilterSheet = false
    var customFilterURLEntries: [URLInputEntry] = [URLInputEntry()]
    var customFilterName: String = ""
    var isAddingCustomFilter = false
    var addCustomFilterError: String?

    // Paste/File mode state
    var customFilterPastedRules: String = ""
    var customFilterTitle: String = ""
    var customFilterDescription: String = ""

    // Auto-update status (for background updates)
    var isAutoUpdating = false
    private var autoUpdatePollingTask: Task<Void, Never>?
    private var customCategoryRefreshTask: Task<Void, Never>?

    // Content blocker enablement modal state
    var showEnableContentBlockersSheet = false
    var disabledContentBlockerNumbers: [Int] = []
    var isCheckingContentBlockerStates = false

    /// Tracks whether the user has toggled standard filters without refreshing
    var hasUnappliedChanges = false

    // MARK: - Computed Properties

    var enabledListsCount: Int {
        filterLists.filter(\.isEnabled).count
    }

    /// Total converted Safari rules (persisted, updated on refresh)
    var totalConvertedRules: Int = 0

    var totalRulesFormatted: String {
        Formatters.ruleCount.string(from: NSNumber(value: totalConvertedRules))
            ?? "\(totalConvertedRules)"
    }

    private func loadTotalConvertedRules() {
        totalConvertedRules = userDefaults.integer(
            forKey: Self.totalConvertedRulesKey
        )
    }

    private func saveTotalConvertedRules(_ count: Int) {
        totalConvertedRules = count
        userDefaults.set(count, forKey: Self.totalConvertedRulesKey)
    }

    func filterLists(for category: FilterCategory) -> [FilterList] {
        var lists = filterLists.filter { $0.category == category }

        // Filter out developer filters if setting is disabled
        if !showDeveloperFilters {
            lists = lists.filter { !$0.developer }
        }

        // Apply search filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            lists = lists.filter { filter in
                filter.name.lowercased().contains(query)
                    || filter.description.lowercased().contains(query)
                    || filter.category.rawValue.lowercased().contains(query)
            }
        }

        return showEnabledOnly ? lists.filter(\.isEnabled) : lists
    }

    var categoriesWithFilters: [FilterCategory] {
        FilterCategory.displayOrder.filter { category in
            !filterLists(for: category).isEmpty
        }
    }

    init() {
        userDefaults =
            UserDefaults(suiteName: GroupIdentifier.shared.value)
            ?? .standard
        loadDefaultFilters()
        migratePersistedBuiltInFilterIdentifiersIfNeeded()
        loadCustomFilters()
        loadSavedEnabledStates()
        loadSavedMetadata()
        loadTotalConvertedRules()
        saveEnabledStates()
        saveMetadata()
    }

    // MARK: - Auto-Update Status Polling

    /// Starts polling for auto-update status changes
    func startAutoUpdatePolling() {
        // Cancel any existing polling task
        autoUpdatePollingTask?.cancel()

        autoUpdatePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAutoUpdateStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops polling for auto-update status
    func stopAutoUpdatePolling() {
        autoUpdatePollingTask?.cancel()
        autoUpdatePollingTask = nil
    }

    /// Checks the current auto-update status from FilterUpdateManager
    private func checkAutoUpdateStatus() async {
        let status = await FilterUpdateManager.shared.getStatus()
        if isAutoUpdating != status.isRunning {
            withAnimation(.easeInOut(duration: 0.3)) {
                isAutoUpdating = status.isRunning
            }
        }
    }

    /// Checks whether all required Safari content blockers are enabled.
    func refreshContentBlockerEnablementState() async {
        isCheckingContentBlockerStates = true
        defer { isCheckingContentBlockerStates = false }

        let states = await Self.loadContentBlockerEnabledStates()
        disabledContentBlockerNumbers =
            states
            .filter { !$0.isEnabled }
            .map { $0.category.rawValue }
            .sorted()
        showEnableContentBlockersSheet = !disabledContentBlockerNumbers.isEmpty
    }

    private nonisolated static func loadContentBlockerEnabledStates() async
        -> [(category: ContentBlockerCategory, isEnabled: Bool)]
    {
        let categoriesToCheck = availableContentBlockerCategories()
        var results: [(ContentBlockerCategory, Bool)] = []
        results.reserveCapacity(categoriesToCheck.count)

        // SFContentBlockerManager state reads can trip XPC API misuse assertions when
        // issued concurrently. Query each blocker state sequentially instead.
        for category in categoriesToCheck {
            let identifier = ContentBlockerIdentifier.identifier(for: category)
            let isEnabled = await Self.loadContentBlockerStateEnabled(
                identifier: identifier
            )
            results.append((category, isEnabled))
        }

        return results.sorted { $0.0.rawValue < $1.0.rawValue }
    }

    /// Returns blocker categories that are embedded in this app build.
    /// If enumeration fails, falls back to all categories.
    private nonisolated static func availableContentBlockerCategories()
        -> [ContentBlockerCategory]
    {
        let allCategories = ContentBlockerCategory.allCases

        guard
            let plugInsURL = Bundle.main.builtInPlugInsURL,
            let plugInURLs = try? FileManager.default.contentsOfDirectory(
                at: plugInsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return allCategories
        }

        let embeddedIdentifiers = Set(
            plugInURLs.compactMap { url in
                Bundle(url: url)?.bundleIdentifier
            }
        )

        let embeddedCategories = allCategories.filter { category in
            embeddedIdentifiers.contains(
                ContentBlockerIdentifier.identifier(for: category)
            )
        }

        return embeddedCategories.isEmpty ? allCategories : embeddedCategories
    }

    @MainActor
    private static func loadContentBlockerStateEnabled(
        identifier: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            SFContentBlockerManager.getStateOfContentBlocker(
                withIdentifier: identifier
            ) { state, error in
                if let error {
                    logger.error(
                        "Failed to read content blocker state for \(identifier): \(error.localizedDescription)"
                    )
                }
                continuation.resume(returning: state?.isEnabled ?? false)
            }
        }
    }

    /// Reloads all content blockers from cached filter data
    /// This is called on app startup to ensure Safari has the latest rules
    private func reloadContentBlockersFromCache() async {
        // Group ALL filters by category
        var allFiltersByCategory: [FilterCategory: [FilterList]] = [:]
        for filter in filterLists {
            allFiltersByCategory[filter.category, default: []].append(filter)
        }
        let hasEnabledFilters = filterLists.contains { $0.isEnabled }
        var combinedAdvancedInputRules = ""

        for (category, filtersInCategory) in allFiltersByCategory {
            let enabledFilters = filtersInCategory.filter(\.isEnabled)

            // Check if this category's JSON rules file exists
            let hasExistingRulesFile = Self.hasConvertedRulesFile(for: category)

            // Skip categories that have never had a rules file
            guard hasExistingRulesFile else { continue }

            if enabledFilters.isEmpty {
                // No enabled filters but has existing rules file - clear the content blocker
                Self.saveEmptyContentBlocker(for: category)
                Self.reloadContentBlocker(for: category)
                continue
            }

            // Collect cached content for enabled filters in this category
            var combinedRules = ""
            for filter in enabledFilters {
                if let content = Self.loadRawFilterContent(filterID: filter.id)
                {
                    combinedRules += content + "\n"
                    appendRules(content, to: &combinedAdvancedInputRules)
                }
            }

            // If we have cached content, convert and reload
            if !combinedRules.isEmpty {
                _ = Self.convertAndSaveRules(
                    rules: combinedRules,
                    category: category
                )
                Self.reloadContentBlocker(for: category)
            }
            // If no cached content for enabled filters, the rules file already exists
            // from a previous session, so we don't need to do anything
        }

        if !hasEnabledFilters {
            ContentBlockerService.rebuildAdvancedBlockingEngine(
                groupIdentifier: GroupIdentifier.shared.value
            )
        } else if !combinedAdvancedInputRules.isEmpty {
            let advancedRules = ContentBlockerService.extractAdvancedRules(
                from: combinedAdvancedInputRules
            )
            ContentBlockerService.rebuildAdvancedBlockingEngine(
                groupIdentifier: GroupIdentifier.shared.value,
                advancedRules: advancedRules
            )
        }
    }

    // MARK: - Persistence

    /// Migrates persisted built-in filter state from legacy string IDs to generated UUIDs.
    private func migratePersistedBuiltInFilterIdentifiersIfNeeded() {
        guard
            let metadataData = userDefaults.data(
                forKey: Self.filterMetadataKey
            ),
            let metadataList = try? JSONDecoder().decode(
                [FilterListMetadata].self,
                from: metadataData
            ),
            !metadataList.isEmpty
        else { return }

        var currentIDByCategoryAndURL: [String: String] = [:]
        var idsByURL: [String: [String]] = [:]
        for filter in filterLists where filter.category != .custom {
            guard let downloadURL = filter.downloadURL else { continue }
            let normalizedURL = Self.normalizedURLString(downloadURL)
            let categoryAndURLKey = Self.builtInLookupKey(
                category: filter.category.rawValue,
                normalizedURL: normalizedURL
            )
            currentIDByCategoryAndURL[categoryAndURLKey] = filter.id
            idsByURL[normalizedURL, default: []].append(filter.id)
        }

        var currentIDByUniqueURL: [String: String] = [:]
        for (url, ids) in idsByURL {
            let uniqueIDs = Set(ids)
            guard uniqueIDs.count == 1, let onlyID = uniqueIDs.first else {
                continue
            }
            currentIDByUniqueURL[url] = onlyID
        }

        var legacyIDMap: [String: String] = [:]
        for metadata in metadataList {
            if metadata.id.hasPrefix("custom-") { continue }

            if let category = metadata.category,
                category.caseInsensitiveCompare(FilterCategory.custom.rawValue)
                    == .orderedSame
            {
                continue
            }

            guard let downloadURL = metadata.downloadURL else { continue }
            let normalizedURL = Self.normalizedURLString(downloadURL)
            let categoryAndURLKey = Self.builtInLookupKey(
                category: metadata.category,
                normalizedURL: normalizedURL
            )

            guard
                let currentID =
                    currentIDByCategoryAndURL[categoryAndURLKey]
                    ?? currentIDByUniqueURL[normalizedURL],
                currentID != metadata.id
            else { continue }

            legacyIDMap[metadata.id] = currentID
        }

        guard !legacyIDMap.isEmpty else { return }

        migrateEnabledStateIdentifiers(using: legacyIDMap)
        migrateFilterMetadataIdentifiers(
            metadataList: metadataList,
            using: legacyIDMap
        )
        migrateCachedFilterFiles(using: legacyIDMap)
        migrateFilterUpdateStateIdentifiers(using: legacyIDMap)

        logger.info(
            "Migrated \(legacyIDMap.count) built-in filter identifiers to UUIDs"
        )
    }

    private func migrateEnabledStateIdentifiers(using idMap: [String: String]) {
        let enabledIDs =
            userDefaults.stringArray(forKey: Self.enabledFiltersKey)
            ?? []
        let migratedEnabledIDs = Self.remapIdentifiers(
            enabledIDs,
            using: idMap
        )
        if migratedEnabledIDs != enabledIDs {
            userDefaults.set(migratedEnabledIDs, forKey: Self.enabledFiltersKey)
        }

        let disabledIDs =
            userDefaults.stringArray(forKey: Self.disabledFiltersKey)
            ?? []
        let migratedDisabledIDs = Self.remapIdentifiers(
            disabledIDs,
            using: idMap
        )
        if migratedDisabledIDs != disabledIDs {
            userDefaults.set(
                migratedDisabledIDs,
                forKey: Self.disabledFiltersKey
            )
        }
    }

    private func migrateFilterMetadataIdentifiers(
        metadataList: [FilterListMetadata],
        using idMap: [String: String]
    ) {
        var migratedMetadata: [FilterListMetadata] = []
        migratedMetadata.reserveCapacity(metadataList.count)

        var seenIdentifiers: Set<String> = []
        seenIdentifiers.reserveCapacity(metadataList.count)

        var changed = false
        for var entry in metadataList {
            if let newID = idMap[entry.id], newID != entry.id {
                entry.id = newID
                changed = true
            }

            if seenIdentifiers.insert(entry.id).inserted {
                migratedMetadata.append(entry)
            } else {
                changed = true
            }
        }

        guard changed else { return }

        do {
            let data = try JSONEncoder().encode(migratedMetadata)
            userDefaults.set(data, forKey: Self.filterMetadataKey)
        } catch {
            logger.error(
                "Failed to migrate filter metadata IDs: \(error.localizedDescription)"
            )
        }
    }

    private func migrateCachedFilterFiles(using idMap: [String: String]) {
        let fileManager = FileManager.default

        for (legacyID, currentID) in idMap where legacyID != currentID {
            guard
                let legacyFileURL = Self.rawFilterFileURL(filterID: legacyID),
                let currentFileURL = Self.rawFilterFileURL(filterID: currentID),
                fileManager.fileExists(atPath: legacyFileURL.path)
            else {
                continue
            }

            do {
                if fileManager.fileExists(atPath: currentFileURL.path) {
                    try fileManager.removeItem(at: legacyFileURL)
                } else {
                    try fileManager.moveItem(
                        at: legacyFileURL,
                        to: currentFileURL
                    )
                }
            } catch {
                logger.warning(
                    "Failed to migrate cache file \(legacyID) -> \(currentID): \(error.localizedDescription)"
                )
            }
        }
    }

    private func migrateFilterUpdateStateIdentifiers(
        using idMap: [String: String]
    ) {
        migrateStringDictionaryValues(
            forKey: Self.filterETagsKey,
            using: idMap
        )
        migrateStringDictionaryValues(
            forKey: Self.filterLastModifiedKey,
            using: idMap
        )
        migrateStringArrayDictionaryValues(
            forKey: Self.lastAppliedFiltersByCategoryKey,
            using: idMap
        )
    }

    private func migrateStringDictionaryValues(
        forKey key: String,
        using idMap: [String: String]
    ) {
        guard
            var dictionary = userDefaults.dictionary(forKey: key)
                as? [String: String]
        else {
            return
        }

        var changed = false
        for (legacyID, currentID) in idMap where legacyID != currentID {
            guard let value = dictionary.removeValue(forKey: legacyID) else {
                continue
            }

            if dictionary[currentID] == nil {
                dictionary[currentID] = value
            }
            changed = true
        }

        if changed {
            userDefaults.set(dictionary, forKey: key)
        }
    }

    private func migrateStringArrayDictionaryValues(
        forKey key: String,
        using idMap: [String: String]
    ) {
        guard
            var dictionary = userDefaults.dictionary(forKey: key)
                as? [String: [String]]
        else {
            return
        }

        var changed = false
        for dictionaryKey in Array(dictionary.keys) {
            guard let ids = dictionary[dictionaryKey] else { continue }
            let migratedIDs = Self.remapIdentifiers(ids, using: idMap)
            if migratedIDs != ids {
                dictionary[dictionaryKey] = migratedIDs
                changed = true
            }
        }

        if changed {
            userDefaults.set(dictionary, forKey: key)
        }
    }

    private nonisolated static func builtInLookupKey(
        category: String?,
        normalizedURL: String
    ) -> String {
        let normalizedCategory =
            category?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return "\(normalizedCategory)|\(normalizedURL)"
    }

    private nonisolated static func normalizedURLString(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private nonisolated static func remapIdentifiers(
        _ identifiers: [String],
        using idMap: [String: String]
    ) -> [String] {
        var remapped: [String] = []
        remapped.reserveCapacity(identifiers.count)

        var seen: Set<String> = []
        seen.reserveCapacity(identifiers.count)

        for identifier in identifiers {
            let mappedIdentifier = idMap[identifier] ?? identifier
            if seen.insert(mappedIdentifier).inserted {
                remapped.append(mappedIdentifier)
            }
        }

        return remapped
    }

    /// Loads saved enabled/disabled states from UserDefaults
    private func loadSavedEnabledStates() {
        let enabledIDs = Set(
            userDefaults.stringArray(forKey: Self.enabledFiltersKey) ?? []
        )
        let disabledIDs = Set(
            userDefaults.stringArray(forKey: Self.disabledFiltersKey) ?? []
        )

        // Only apply saved states if we have any saved data
        guard !enabledIDs.isEmpty || !disabledIDs.isEmpty else { return }

        for index in filterLists.indices {
            let id = filterLists[index].id
            if enabledIDs.contains(id) {
                filterLists[index].isEnabled = true
            } else if disabledIDs.contains(id) {
                filterLists[index].isEnabled = false
            }
            // If neither set contains the ID, keep the default state
        }
    }

    /// Saves current enabled/disabled states to UserDefaults
    private func saveEnabledStates() {
        var enabledIDs: [String] = []
        var disabledIDs: [String] = []
        enabledIDs.reserveCapacity(filterLists.count)
        disabledIDs.reserveCapacity(filterLists.count)

        for filter in filterLists {
            if filter.isEnabled {
                enabledIDs.append(filter.id)
            } else {
                disabledIDs.append(filter.id)
            }
        }

        userDefaults.set(enabledIDs, forKey: Self.enabledFiltersKey)
        userDefaults.set(disabledIDs, forKey: Self.disabledFiltersKey)
    }

    /// Loads saved filter metadata from UserDefaults
    private func loadSavedMetadata() {
        guard let data = userDefaults.data(forKey: Self.filterMetadataKey),
            let metadataList = try? JSONDecoder().decode(
                [FilterListMetadata].self,
                from: data
            )
        else { return }

        var metadataByID: [String: FilterListMetadata] = [:]
        metadataByID.reserveCapacity(metadataList.count)
        for metadata in metadataList {
            metadataByID[metadata.id] = metadata
        }

        for index in filterLists.indices {
            if let metadata = metadataByID[filterLists[index].id] {
                filterLists[index].version = metadata.version
                filterLists[index].ruleCount = metadata.ruleCount
                filterLists[index].lastUpdated = metadata.lastUpdated
            }
        }
    }

    /// Saves filter metadata to UserDefaults
    private func saveMetadata() {
        let metadataList = filterLists.map { filter in
            FilterListMetadata(
                id: filter.id,
                version: filter.version,
                ruleCount: filter.ruleCount ?? -1,
                lastUpdated: filter.lastUpdated ?? Date(),
                sourceRuleCount: filter.ruleCount ?? 0,
                downloadURL: filter.downloadURL,
                category: filter.category.rawValue
            )
        }

        do {
            let data = try JSONEncoder().encode(metadataList)
            userDefaults.set(data, forKey: Self.filterMetadataKey)
        } catch {
            logger.error(
                "Failed to encode filter metadata: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Custom Filter Management

    /// Loads user-added custom filters from persistence
    private func loadCustomFilters() {
        guard let data = userDefaults.data(forKey: Self.customFiltersKey),
            let entries = try? JSONDecoder().decode(
                [CustomFilterEntry].self,
                from: data
            )
        else { return }

        for entry in entries {
            let filter = FilterList(
                id: entry.id,
                name: entry.name,
                description:
                    "Custom filter added on \(entry.dateAdded.formatted(date: .abbreviated, time: .omitted))",
                version: "N/A",
                category: .custom,
                downloadURL: entry.downloadURL,
                isEnabled: entry.isEnabled,
                lastUpdated: entry.dateAdded
            )
            filterLists.append(filter)
        }
    }

    /// Saves custom filter entries to UserDefaults
    private func saveCustomFilters() {
        let customFilters = filterLists.filter(\.isCustomFilter)
        let entries = customFilters.compactMap { filter -> CustomFilterEntry? in
            guard let url = filter.downloadURL else { return nil }
            return CustomFilterEntry(
                id: filter.id,
                name: filter.name,
                downloadURL: url,
                isEnabled: filter.isEnabled,
                dateAdded: filter.lastUpdated ?? Date()
            )
        }

        do {
            let data = try JSONEncoder().encode(entries)
            userDefaults.set(data, forKey: Self.customFiltersKey)
        } catch {
            logger.error(
                "Failed to save custom filters: \(error.localizedDescription)"
            )
        }
    }

    /// Adds one or more custom filter URLs
    func addCustomFilter(urls: [String], name: String?) async throws {
        // Prevent adding filters during refresh to avoid index invalidation
        guard !isRefreshing else {
            throw FilterListError.downloadFailed(
                "Cannot add filters while refresh is in progress"
            )
        }

        isAddingCustomFilter = true
        addCustomFilterError = nil

        defer { isAddingCustomFilter = false }

        // Validate and parse URLs
        var validURLs: [URL] = []
        for urlString in urls {
            let trimmed = urlString.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { continue }

            guard let url = URL(string: trimmed),
                url.scheme == "http" || url.scheme == "https"
            else {
                throw FilterListError.invalidURL
            }

            // Check for duplicates
            if filterLists.contains(where: { $0.downloadURL == url }) {
                throw FilterListError.duplicateURL(url.absoluteString)
            }

            validURLs.append(url)
        }

        guard !validURLs.isEmpty else {
            throw FilterListError.invalidURL
        }

        // Add each URL as a separate filter
        for (index, url) in validURLs.enumerated() {
            let filterID = "custom-\(UUID().uuidString)"

            // Download the filter to extract metadata
            let content = try await downloadFilterList(from: url)

            guard
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw FilterListError.emptyContent
            }

            let header = FilterListHeaderParser.parseHeader(from: content)

            // Determine the filter name
            let filterName: String
            if let providedName = name, !providedName.isEmpty {
                filterName =
                    validURLs.count > 1
                    ? "\(providedName) (\(index + 1))" : providedName
            } else {
                filterName = header.title ?? url.host ?? "Custom Filter"
            }

            // Create and add the filter
            let ruleCount = FilterListHeaderParser.countRules(in: content)
            let filter = FilterList(
                id: filterID,
                name: filterName,
                description: "Custom filter from \(url.host ?? "unknown")",
                version: header.version ?? "N/A",
                ruleCount: ruleCount,
                category: .custom,
                downloadURL: url,
                homepageURL: header.homepage.flatMap { URL(string: $0) },
                isEnabled: true,
                lastUpdated: Date()
            )

            filterLists.append(filter)

            // Save raw content for caching
            Self.saveRawFilterContent(content, filterID: filterID)
        }

        // Persist the new custom filters
        saveCustomFilters()
        saveEnabledStates()
        saveMetadata()

        // Trigger conversion for custom category
        await refreshCustomCategory()
    }

    /// Adds a user-created filter list from pasted or file content
    /// - Parameters:
    ///   - name: The display name for the filter
    ///   - description: Optional description (defaults to "User-created list")
    ///   - content: The filter rules content
    func addUserList(name: String, description: String?, content: String)
        async throws
    {
        // Prevent adding filters during refresh
        guard !isRefreshing else {
            throw FilterListError.downloadFailed(
                "Cannot add filters while refresh is in progress"
            )
        }

        let trimmedContent = content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedContent.isEmpty else {
            throw FilterListError.emptyContent
        }

        isAddingCustomFilter = true
        addCustomFilterError = nil
        defer { isAddingCustomFilter = false }

        let filterID = "custom-\(UUID().uuidString)"
        let userListURL = URL(string: "webshield://userlist/\(filterID)")!

        // Check for duplicate names (optional, allow duplicates for user lists)
        let header = FilterListHeaderParser.parseHeader(from: trimmedContent)
        let ruleCount = FilterListHeaderParser.countRules(in: trimmedContent)

        let filter = FilterList(
            id: filterID,
            name: name,
            description: description ?? "User-created list",
            version: header.version ?? "N/A",
            ruleCount: ruleCount,
            category: .custom,
            downloadURL: userListURL,
            homepageURL: header.homepage.flatMap { URL(string: $0) },
            isEnabled: true,
            lastUpdated: Date()
        )

        filterLists.append(filter)

        // Save the content directly
        Self.saveRawFilterContent(trimmedContent, filterID: filterID)

        // Persist the new custom filter
        saveCustomFilters()
        saveEnabledStates()
        saveMetadata()

        // Trigger conversion for custom category
        await refreshCustomCategory()
    }

    /// Adds a user-created filter list from a file
    /// - Parameters:
    ///   - fileURL: The URL of the file to import
    ///   - title: The display name for the filter
    ///   - description: Optional description
    func addUserListFromFile(fileURL: URL, title: String, description: String?)
        async throws
    {
        // Access security-scoped resource if needed
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        try await addUserList(
            name: title,
            description: description,
            content: content
        )
    }

    /// Refreshes only the custom category content blocker
    private func refreshCustomCategory() async {
        let customFilterIDs =
            filterLists
            .filter { $0.category == .custom && $0.isEnabled }
            .map(\.id)

        guard !customFilterIDs.isEmpty else {
            // Clear the custom content blocker if no enabled custom filters
            if Self.hasConvertedRulesFile(for: .custom) {
                await Self.runBackground {
                    Self.saveEmptyContentBlocker(for: .custom)
                    Self.reloadContentBlocker(for: .custom)
                }
            }
            return
        }

        let combinedRules = await Self.runBackground {
            var combinedRulesParts: [String] = []
            combinedRulesParts.reserveCapacity(customFilterIDs.count)

            for filterID in customFilterIDs {
                guard
                    let content = Self.loadRawFilterContent(filterID: filterID)
                else { continue }

                let trimmed = content.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else { continue }
                combinedRulesParts.append(content)
            }

            return combinedRulesParts.joined(separator: "\n")
        }

        guard !combinedRules.isEmpty else { return }

        let conversionResult = await Self.runBackground {
            let result = Self.convertAndSaveRules(
                rules: combinedRules,
                category: .custom
            )
            Self.reloadContentBlocker(for: .custom)
            return result
        }

        let advancedRules = conversionResult.advancedRulesText ?? ""
        guard
            !advancedRules.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        else { return }

        await Self.runBackground {
            ContentBlockerService.rebuildAdvancedBlockingEngine(
                groupIdentifier: GroupIdentifier.shared.value,
                advancedRules: advancedRules
            )
        }
    }

    /// Deletes a custom filter
    func deleteCustomFilter(_ filter: FilterList) {
        guard filter.isCustomFilter else { return }

        // Prevent deleting filters during refresh to avoid index invalidation
        guard !isRefreshing else {
            logger.warning(
                "Attempted to delete filter during refresh, ignoring"
            )
            return
        }

        // Remove from list
        filterLists.removeAll { $0.id == filter.id }

        // Delete cached content file
        if let fileURL = Self.rawFilterFileURL(filterID: filter.id) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        // Persist changes
        saveCustomFilters()
        saveEnabledStates()
        saveMetadata()

        // Refresh the custom category
        scheduleCustomCategoryRefresh()
    }

    /// Resets the add custom filter form state
    func resetCustomFilterForm() {
        customFilterURLEntries = [URLInputEntry()]
        customFilterName = ""
        addCustomFilterError = nil
        // Reset paste/file mode state
        customFilterPastedRules = ""
        customFilterTitle = ""
        customFilterDescription = ""
    }

    // MARK: - File Storage Helpers

    /// Returns the URL for the shared filter-list cache directory.
    private nonisolated static func filterListsDirectoryURL() -> URL? {
        guard let appGroupURL = appGroupURL else { return nil }
        let directoryURL = appGroupURL.appendingPathComponent(
            AppGroupSubfolder.filterLists,
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
            logger.error(
                "Failed to create filter lists directory: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Returns the file URL for a filter's raw content
    private nonisolated static func rawFilterFileURL(filterID: String) -> URL? {
        filterListsDirectoryURL()?.appendingPathComponent(
            "filter-\(filterID).txt"
        )
    }

    /// Returns the file URL for a category's converted rules
    private nonisolated static func rulesFileURL(for category: FilterCategory)
        -> URL?
    {
        appGroupURL?.appendingPathComponent(category.rulesFilename)
    }

    /// Adds a unique query item so intermediaries treat this as a fresh request.
    private nonisolated static func cacheBustingURL(from url: URL) -> URL {
        guard
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else {
            return url
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(
            URLQueryItem(name: "_webshield_refresh", value: UUID().uuidString)
        )
        components.queryItems = queryItems
        return components.url ?? url
    }

    /// Saves raw filter content to the app group container
    private nonisolated static func saveRawFilterContent(
        _ content: String,
        filterID: String
    ) {
        guard let fileURL = Self.rawFilterFileURL(filterID: filterID) else {
            logger.error(
                "Failed to get app group URL for saving filter: \(filterID)"
            )
            return
        }

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error(
                "Failed to save filter content for \(filterID): \(error.localizedDescription)"
            )
        }
    }

    /// Loads raw filter content from the app group container
    private nonisolated static func loadRawFilterContent(
        filterID: String
    ) -> String? {
        guard let fileURL = Self.rawFilterFileURL(filterID: filterID) else {
            logger.error(
                "Failed to get app group URL for loading filter: \(filterID)"
            )
            return nil
        }

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            logger.debug(
                "No cached content for filter \(filterID): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Checks if the converted JSON rules file exists for a category
    private nonisolated static func hasConvertedRulesFile(
        for category: FilterCategory
    ) -> Bool {
        guard let fileURL = Self.rulesFileURL(for: category) else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func loadDefaultFilters() {
        let baseUrl =
            "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/refs/heads/master/platforms/extension/safari/filters"
        filterLists = [
            // Ads
            FilterList(
                name: "AdGuard Base Filter",
                description:
                    "EasyList + AdGuard English filter. This filter is necessary for quality ad blocking.",
                version: "N/A",

                category: .ads,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/2_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: true
            ),
            // Privacy
            FilterList(
                name: "AdGuard Tracking Protection Filter",
                description:
                    "The most comprehensive list of various online counters and web analytics tools. Use this filter if you do not want your actions on the Internet to be tracked.",
                version: "N/A",

                category: .privacy,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/3_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: true
            ),
            FilterList(
                name: "EasyPrivacy",
                description: "Privacy protection supplement for EasyList.",
                version: "N/A",
                category: .privacy,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/118_optimized.txt"
                ),
                homepageURL: URL(
                    string: "https://easylist.to/"
                ),
                isEnabled: false
            ),

            // Security
            FilterList(
                name: "Online Suspicious URL Blocklist",
                description:
                    "Blocks domains that are known to be used to propagate unwanted software and tracking software.",
                version: "N/A",
                category: .security,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/208_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://gitlab.com/malware-filter/urlhaus-filter#malicious-url-blocklist"
                ),
                isEnabled: false
            ),
            FilterList(
                name: "Phishing URL Blocklist",
                description:
                    "Phishing URL blocklist for uBlock Origin (uBO), AdGuard, Vivaldi, Pi-hole, Hosts file, Dnsmasq, BIND, Unbound, Snort and Suricata.",
                version: "N/A",
                category: .security,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/255_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://gitlab.com/malware-filter/phishing-filter#phishing-url-blocklist"
                ),
                isEnabled: false
            ),

            // Multipurpose
            FilterList(
                name: "Peter Lowe's Blocklist",
                description:
                    "Filter that blocks ads, trackers, and other nasty things.",
                version: "N/A",
                category: .multipurpose,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/204_optimized.txt"
                ),
                isEnabled: false
            ),
            FilterList(
                name: "Bypass Paywalls Clean filter",
                description:
                    "Filters for news sites (supports less sites than the extension/add-on).",
                version: "N/A",
                category: .multipurpose,
                downloadURL: URL(
                    string:
                        "https://gitflic.ru/project/magnolia1234/bypass-paywalls-clean-filters/blob/raw?file=bpc-paywall-filter.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://gitflic.ru/project/magnolia1234/bypass-paywalls-clean-filters"
                ),
                isEnabled: false
            ),

            // Cookies
            FilterList(
                name: "EasyList Cookie List",
                description:
                    "Blocks cookie banners and cookie consent notices on websites.",
                version: "N/A",
                category: .cookies,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/241_optimized.txt"
                ),
                homepageURL: URL(
                    string: "https://github.com/easylist/easylist#fanboy-lists"
                ),
                isEnabled: false
            ),
            FilterList(
                name: "AdGuard Cookie Notices filter",
                description:
                    "Blocks cookie notices on web pages.",
                version: "N/A",
                category: .cookies,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/18_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),

            // Social
            FilterList(
                name: "AdGuard Social Media filter",
                description:
                    "Filter for social media widgets such as 'Like' and 'Share' buttons and more.",
                version: "N/A",
                category: .social,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/4_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),
            FilterList(
                name: "Fanboy's Social Blocking List",
                description:
                    "Hides and blocks social content, social widgets, social scripts and social icons. Already included in Fanboy's Annoyances list.",
                version: "N/A",
                category: .social,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/123_optimized.txt"
                ),
                homepageURL: URL(
                    string: "https://github.com/easylist/easylist#fanboy-lists"
                ),
                isEnabled: false
            ),
            FilterList(
                name: "Fanboy's Anti-Facebook List",
                description:
                    "Warning, it will break Facebook-based comments on some websites and may also break some Facebook apps or games.",
                version: "N/A",

                category: .social,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/225_optimized.txt"
                ),
                homepageURL: URL(
                    string: "https://www.fanboy.co.nz"
                ),
                isEnabled: false
            ),

            // Annoyances
            FilterList(
                name: "AdGuard Annoyances filter",
                description:
                    "Blocks irritating elements on web pages including cookie notices, third-party widgets and in-page pop-ups. Contains the following AdGuard filters: Cookie Notices, Popups, Mobile App Banners, Other Annoyances and Widgets.",
                version: "N/A",
                category: .annoyances,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/14_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),

            FilterList(
                name: "AdGuard Popups filter",
                description:
                    "Blocks all kinds of pop-ups that are not necessary for websites' operation according to our Filter policy.",
                version: "N/A",
                category: .annoyances,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/19_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),

            FilterList(
                name: "AdGuard Mobile App Banners filter",
                description:
                    "Blocks irritating banners that promote mobile apps of websites.",
                version: "N/A",
                category: .annoyances,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/20_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),

            FilterList(
                name: "AdGuard Other Annoyances filter",
                description:
                    "Blocks irritating elements on web pages that do not fall under the popular categories of annoyances.",
                version: "N/A",
                category: .annoyances,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/21_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),

            FilterList(
                name: "AdGuard Widgets filter",
                description:
                    "Blocks annoying third-party widgets: online assistants, live support chats, etc.",
                version: "N/A",
                category: .annoyances,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/22_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),

            FilterList(
                name: "Fanboy's Annoyance List",
                description:
                    "Removes in-page pop-ups and other annoyances. Includes Fanboy's Social Blocking & EasyList Cookie Lists.",
                version: "N/A",
                category: .annoyances,
                downloadURL: URL(
                    string: "https://easylist.to/easylist/fanboy-annoyance.txt"
                ),
                isEnabled: false
            ),

            // Regional
            FilterList(
                name: "AdGuard Chinese filter",
                description:
                    "EasyList China + AdGuard Chinese filter. Filter list that specifically removes ads on websites in Chinese language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/224_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["zh"],
            ),

            FilterList(
                name: "AdGuard Dutch filter",
                description:
                    "EasyList Dutch + AdGuard Dutch filter. Filter list that specifically removes ads on websites in Dutch language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/8_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["nl"],
            ),

            FilterList(
                name: "AdGuard French filter",
                description:
                    "Liste FR + AdGuard French filter. Filter list that specifically removes ads on websites in French language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/16_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["fr"],
            ),

            FilterList(
                name: "AdGuard German filter",
                description:
                    "EasyList Germany + AdGuard German filter. Filter list that specifically removes ads on websites in German language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/6_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["de"],
            ),

            FilterList(
                name: "AdGuard Japanese filter",
                description:
                    "Filter that enables ad blocking on websites in Japanese language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/7_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["ja"],
            ),

            FilterList(
                name: "AdGuard Russian filter",
                description:
                    "Filter that enables ad blocking on websites in Russian language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/1_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["ru"],
            ),

            FilterList(
                name: "AdGuard Spanish/Portuguese filter",
                description:
                    "Filter list that specifically removes ads on websites in Spanish, Portuguese, and Brazilian Portuguese languages.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/9_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["es", "pt"],
            ),

            FilterList(
                name: "AdGuard Turkish filter",
                description:
                    "Filter list that specifically removes ads on websites in Turkish language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/13_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["tr"],
            ),

            FilterList(
                name: "AdGuard Ukrainian filter",
                description:
                    "Filter that enables ad blocking on websites in Ukrainian language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/23_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false,
                languages: ["uk"],
            ),

            FilterList(
                name: "ABPVN List",
                description:
                    "Vietnamese adblock filter list.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/214_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://abpvn.com/"
                ),
                isEnabled: false,
                languages: ["vi"],
            ),

            FilterList(
                name: "ABPindo",
                description:
                    "Additional filter list for websites in Indonesian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/102_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/ABPindo/indonesianadblockrules"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "AdBlockID",
                description:
                    "Additional filter list for websites in Indonesian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/120_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/realodix/AdBlockID"
                ),
                isEnabled: false,
                languages: ["id"],
            ),

            FilterList(
                name: "Adblock List for Finland",
                description:
                    "Finnish ad blocking filter list.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/233_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/finnish-easylist-addition/finnish-easylist-addition"
                ),
                isEnabled: false,
                languages: ["fi"],
            ),

            FilterList(
                name: "Bulgarian list",
                description:
                    "Additional filter list for websites in Bulgarian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/103_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/RealEnder/adblockbg/"
                ),
                isEnabled: false,
                languages: ["bg"],
            ),

            FilterList(
                name: "CJX's Annoyances List",
                description:
                    "Supplement for EasyList China+EasyList and EasyPrivacy.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/220_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/cjx82630/cjxlist/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Dandelion Sprout's Serbo-Croatian List",
                description:
                    "A filter list for websites in Serbian, Montenegrin, Croatian, and Bosnian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/252_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/DandelionSprout/adfilt"
                ),
                isEnabled: false,
                languages: ["sr", "hr"],
            ),

            FilterList(
                name: "EasyList China",
                description:
                    "Additional filter list for websites in Chinese. Already included in AdGuard Chinese filter.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/104_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/easylistchina"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "EasyList Czech and Slovak",
                description:
                    "Additional filter list for websites in Czech and Slovak.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/105_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/tomasko126/easylistczechandslovak"
                ),
                isEnabled: false,
                languages: ["cs", "sk"],
            ),

            FilterList(
                name: "EasyList Dutch",
                description:
                    "Additional filter list for websites in Dutch. Already included in AdGuard Dutch filter.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/106_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/easylistdutch/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "EasyList Germany",
                description:
                    "Additional filter list for websites in German. Already included in AdGuard German filter.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/107_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/easylistgermany/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "EasyList Hebrew",
                description:
                    "Additional filter list for websites in Hebrew.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/108_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/EasyListHebrew"
                ),
                isEnabled: false,
                languages: ["he"],
            ),

            FilterList(
                name: "EasyList Italy",
                description:
                    "Additional filter list for websites in Italian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/109_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/easylistitaly/"
                ),
                isEnabled: false,
                languages: ["it"],
            ),

            FilterList(
                name: "EasyList Lithuania",
                description:
                    "Additional filter list for websites in Lithuanian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/110_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/EasyList-Lithuania/easylist_lithuania"
                ),
                isEnabled: false,
                languages: ["lt"],
            ),

            FilterList(
                name: "EasyList Polish",
                description:
                    "Additional filter list for websites in Polish.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/246_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylistpolish/easylistpolish/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "EasyList Portuguese",
                description:
                    "Additional filter list for websites in Spanish and Portuguese.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/124_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/easylistportuguese"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "EasyList Spanish",
                description:
                    "Additional filter list for websites in Spanish.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/231_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/easylistspanish"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "EasyList Thailand",
                description:
                    "Filter that blocks ads on Thai sites.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/202_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist-thailand/"
                ),
                isEnabled: false,
                languages: ["th"],
            ),

            FilterList(
                name: "Estonian List",
                description:
                    "Filter for ad blocking on Estonian sites.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/218_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/sander85/uBO-et"
                ),
                isEnabled: false,
                languages: ["et"],
            ),

            FilterList(
                name: "Frellwit's Swedish Filter",
                description:
                    "Filter that aims to remove regional Swedish ads, tracking, social media, annoyances, sponsored articles etc.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/243_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/lassekongo83/Frellwit-s-filter-lists"
                ),
                isEnabled: false,
                languages: ["sv"],
            ),

            FilterList(
                name: "Greek AdBlock Filter",
                description:
                    "Additional filter list for websites in Greek.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/121_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/kargig/greek-adblockplus-filter"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Hungarian filter",
                description:
                    "Hufilter. Filter list that specifically removes ads on websites in the Hungarian language.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/203_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/hufilter/hufilter/wiki"
                ),
                isEnabled: false,
                languages: ["hu"],
            ),

            FilterList(
                name: "Icelandic ABP List",
                description:
                    "Additional filter list for websites in Icelandic.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/119_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://adblock.gardar.net/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "IndianList",
                description:
                    "Additional filter list for websites in Hindi, Tamil and other Dravidian and Indic languages.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/253_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/mediumkreation/IndianList"
                ),
                isEnabled: false,
                languages: ["hi"],
            ),

            FilterList(
                name: "KAD - Anti-Scam",
                description:
                    "Filter that protects against various types of scams in the Polish network, such as mass text messaging, fake online stores, etc.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/232_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/FiltersHeroes/KAD"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Latvian List",
                description:
                    "Additional filter list for websites in Latvian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/111_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/Latvian-List/adblock-latvian"
                ),
                isEnabled: false,
                languages: ["lv"],
            ),

            FilterList(
                name: "List-KR",
                description:
                    "Filter that removes ads and various scripts from websites with Korean content. Combined and augmented with AdGuard-specific rules for enhanced filtering. This filter is expected to be used alongside with AdGuard Base filter.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/227_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://list-kr.github.io/"
                ),
                isEnabled: false,
                languages: ["ko"],
            ),

            FilterList(
                name: "Liste AR",
                description:
                    "Additional filter list for websites in Arabic.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/112_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/listear"
                ),
                isEnabled: false,
                languages: ["ar"],
            ),

            FilterList(
                name: "Liste FR",
                description:
                    "Additional filter list for websites in French. Already included in AdGuard French filter.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/113_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/easylist/listefr"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Macedonian adBlock Filters",
                description:
                    "Blocks ads and trackers on various Macedonian websites.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/254_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/DeepSpaceHarbor/Macedonian-adBlock-Filters"
                ),
                isEnabled: false,
                languages: ["mk"],
            ),

            FilterList(
                name:
                    "Official Polish filters for AdBlock, uBlock Origin & AdGuard",
                description:
                    "Additional filter list for websites in Polish.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/216_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/MajkiIT/polish-ads-filter#polish-filters-for-adblock-ublock-origin--adguard"
                ),
                isEnabled: false,
                languages: ["pl"],
            ),

            FilterList(
                name: "Persian Blocker",
                description:
                    "Filter list for blocking ads and trackers on websites in Persian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/235_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/MasterKia/PersianBlocker/"
                ),
                isEnabled: false,
                languages: ["fa", "tg", "ps"],
            ),

            FilterList(
                name: "Polish Annoyances Filters",
                description:
                    "Filter list that hides and blocks pop-ups, widgets, newsletters, push notifications, arrows, tagged internal links that are off-topic, and other irritating elements. Polish GDPR-Cookies Filters is already in it.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/237_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://polishannoyancefilters.netlify.app"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Polish Anti Adblock Filters",
                description:
                    "Official Polish filters against Adblock alerts.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/238_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/olegwukr/polish-privacy-filters"
                ),
                isEnabled: false,
                languages: ["pl"],
            ),

            FilterList(
                name: "Polish Anti-Annoying Special Supplement",
                description:
                    "Filters that block and hide RSS elements and remnants of hidden newsletters combined with social elements on Polish websites.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/247_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/FiltersHeroes/PolishAntiAnnoyingSpecialSupplement/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Polish GDPR-Cookies Filters",
                description:
                    "Polish filter list for cookies blocking.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/217_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/MajkiIT/polish-ads-filter#polish-filters-for-adblock-ublock-origin--adguard"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Polish Social Filters",
                description:
                    "Polish filter list for social widgets, popups, etc.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/221_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/MajkiIT/polish-ads-filter#polish-filters-for-adblock-ublock-origin--adguard"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "ROLIST2",
                description:
                    "This is a complementary list for ROList with annoyances that are not necessarily banners. It is a very aggressive list and not recommended for beginners.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/234_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://zoso.ro/rolist/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "ROList",
                description:
                    "Additional filter list for websites in Romanian.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/114_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://www.zoso.ro/rolist"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "RU AdList: Counters",
                description:
                    "RU AdList supplement for trackers blocking.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/212_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://forums.lanik.us/viewforum.php?f=102"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Xfiles",
                description:
                    "Italian adblock filter list.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/206_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://xfiles.noads.it/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "YousList",
                description:
                    "Filter that blocks ads on Korean sites.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/244_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/yous/YousList/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "road-block light",
                description:
                    "Romanian ad blocking filter subscription.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/236_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/tcptomato/ROad-Block"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "xinggsf",
                description:
                    "Blocks ads on the Chinese video platforms (MangoTV, DouYu and others).",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/228_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/xinggsf/Adblock-Plus-Rule/"
                ),
                isEnabled: false,
                languages: [],
            ),

            FilterList(
                name: "Dandelion Sprout's Nordic Filters",
                description:
                    "This list covers websites for Norway, Denmark, Iceland, Danish territories, and the Sami indigenous population.",
                version: "N/A",
                category: .regional,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/249_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/DandelionSprout/adfilt"
                ),
                isEnabled: false,
                languages: ["no", "da", "is", "fo"],
            ),

            // Experimental
            FilterList(
                name: "AdGuard Experimental filter",
                description:
                    "Filter designed to test certain hazardous filtering rules before they are added to the basic filters.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "\(baseUrl)/5_optimized.txt"
                ),
                homepageURL: URL(
                    string:
                        "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                ),
                informationURL: URL(
                    string:
                        "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                ),
                isEnabled: false
            ),
            FilterList(
                name: "Rules for element hiding rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/element-hiding-rules/test-element-hiding-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name: "Rules for generic hide tests",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/generichide-rules/generichide-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name: "Rules for CSS tests",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/css-rules/css-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name: "Extended CSS rules",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/extended-css-rules/test-extended-css-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name:
                    "Extended CSS rules injection into iframe created with js",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/extended-css-rules/extended-css-iframejs-injection/extended-css-iframejs-injection.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name:
                    "Rules for $important rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/important-rules/test-important-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name:
                    "Rules for websocket rules tests",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/websockets/test-websockets.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name:
                    "Rules for script rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/script-rules/test-script-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
            FilterList(
                name:
                    "Rules for scriptlet rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/scriptlet-rules/test-scriptlet-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Popup rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/PopupBlocker/test-popup-blocker-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for $badfilter rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/badfilter-rules/test-badfilter-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for $jsinject rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/script-rules/jsinject-rules/test-jsinject-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for $denyallow rules test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/denyallow-rules/test-denyallow-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for blocking-request (ping, websocket, xmlhttprequest) tests",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/blocking-request-rules/test-blocking-request-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for subdocument rules tests",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/subdocument-rules/test-subdocument-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for non-basic rules $path modifier test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/nonbasic-path-modifier/test-nonbasic-path-modifier.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for advanced $domain modifier test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/advanced-domain-modifier/test-advanced-domain-modifier.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for $match-case modifier",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/match-case-rules/test-match-case-rules.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for content security policy test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/content-security-policy/test-content-security-policy.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),

            FilterList(
                name:
                    "Rules for Injection speed test",
                description:
                    "Filter to be used for testing purposes.",
                version: "N/A",
                category: .experimental,
                downloadURL: URL(
                    string:
                        "https://testcases.agrd.dev/Filters/injection-speed/test-injection-speed.txt"
                ),
                homepageURL: URL(string: "https://testcases.agrd.dev/"),
                isEnabled: false,
                developer: true
            ),
        ]

        #if os(iOS) || os(visionOS)
            filterLists.append(
                FilterList(
                    name: "AdGuard Mobile Ads Filter",
                    description:
                        "Filter for blocking ads on mobile devices. Contains all known mobile ad networks.",
                    version: "N/A",
                    category: .ads,
                    downloadURL: URL(
                        string:
                            "\(baseUrl)/11_optimized.txt"
                    ),
                    homepageURL: URL(
                        string:
                            "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
                    ),
                    informationURL: URL(
                        string:
                            "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
                    ),
                    isEnabled: true
                )
            )
        #endif
    }

    func setFilterEnabled(_ filter: FilterList, isEnabled: Bool) {
        guard let index = filterLists.firstIndex(where: { $0.id == filter.id })
        else { return }
        guard filterLists[index].isEnabled != isEnabled else { return }

        filterLists[index].isEnabled = isEnabled
        saveEnabledStates()

        if filter.isCustomFilter {
            saveCustomFilters()
            scheduleCustomCategoryRefresh()
        } else {
            hasUnappliedChanges = true
        }
    }

    func toggleFilter(_ filter: FilterList) {
        guard let index = filterLists.firstIndex(where: { $0.id == filter.id })
        else { return }
        setFilterEnabled(filter, isEnabled: !filterLists[index].isEnabled)
    }

    private func scheduleCustomCategoryRefresh() {
        customCategoryRefreshTask?.cancel()
        customCategoryRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.refreshCustomCategory()
        }
    }

    // MARK: - Refresh Helpers

    private nonisolated static func runBackground<T>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }

    private func updateRefreshPhase(_ phase: RefreshPhase) {
        withAnimation(.easeInOut(duration: 0.2)) {
            refreshPhase = phase
        }
    }

    private func advanceRefreshProgress(
        to progress: Double,
        duration: TimeInterval = 0.25
    ) {
        let clamped = min(max(progress, 0), 1)
        guard clamped >= refreshProgress else { return }
        withAnimation(.linear(duration: duration)) {
            refreshProgress = clamped
        }
    }

    private func downloadProgressValue(
        processedCount: Int,
        totalCount: Int
    ) -> Double {
        let base = Constants.refreshPreparationProgress
        let ratio = Double(processedCount) / Double(max(totalCount, 1))
        return base + (ratio * Constants.refreshDownloadProgressRange)
    }

    private func categoryProgressValue(
        categoriesProcessed: Int,
        totalCategories: Int
    ) -> Double {
        let base =
            Constants.refreshPreparationProgress
            + Constants.refreshDownloadProgressRange
        let ratio =
            Double(categoriesProcessed) / Double(max(totalCategories, 1))
        return base + (ratio * Constants.refreshCategoryProgressRange)
    }

    /// Refreshes all filter lists by downloading enabled ones and distributing across blockers
    /// Uses load balancing to evenly distribute rules across content blocker extensions
    /// Uses conditional HTTP requests by default; developer mode can force fresh downloads
    func refreshFilters() async {
        let overallStartTime = Date()
        isRefreshing = true
        showRefreshSheet = true
        refreshProgress = 0
        updateRefreshPhase(.preparing)
        advanceRefreshProgress(
            to: Constants.refreshPreparationProgress,
            duration: 0.2
        )
        refreshStatistics = RefreshStatistics()

        let manager = FilterUpdateManager.shared
        let loadBalancer = LoadBalancer.shared

        // Load previous load balancer state
        await loadBalancer.loadState()

        // Get enabled filters for processing
        let enabledFilters = filterLists.filter { $0.isEnabled }
        let shouldForceFreshDownloads = forceManualRefreshDownloads
        let totalCount = max(enabledFilters.count, 1)
        let totalBlockersToProcess = ContentBlockerCategory.allCases.count

        var processedCount = 0
        var combinedAdvancedInputChunks: [String] = []
        var totalConversionTime: TimeInterval = 0
        var totalReloadTime: TimeInterval = 0
        var totalRulesConverted = 0
        var categoriesProcessed = 0
        var filtersDownloaded = 0
        var filtersSkipped = 0
        var categoriesSkipped = 0
        var errors: [String] = []

        // PHASE 1: Download all enabled filters and collect their content
        logger.debug(
            "Phase 1: Downloading \(enabledFilters.count) enabled filters"
        )

        var downloadedFilters:
            [(
                filterID: String, filter: FilterList, content: String,
                sourceRules: Int
            )] = []

        for filter in enabledFilters {
            guard let url = filter.downloadURL else {
                processedCount += 1
                advanceRefreshProgress(
                    to: downloadProgressValue(
                        processedCount: processedCount,
                        totalCount: totalCount
                    )
                )
                continue
            }

            let filterID = filter.id

            // Use ID-based lookup to safely update filter state
            guard
                let filterIndex = filterLists.firstIndex(where: {
                    $0.id == filterID
                })
            else {
                processedCount += 1
                advanceRefreshProgress(
                    to: downloadProgressValue(
                        processedCount: processedCount,
                        totalCount: totalCount
                    )
                )
                continue
            }

            filterLists[filterIndex].isDownloading = true
            filterLists[filterIndex].lastError = nil

            updateRefreshPhase(
                .downloading(
                    filterName: filter.name,
                    current: processedCount + 1,
                    total: totalCount
                )
            )

            defer {
                if let filterIndex = filterLists.firstIndex(where: {
                    $0.id == filterID
                }) {
                    filterLists[filterIndex].isDownloading = false
                }
                processedCount += 1
                advanceRefreshProgress(
                    to: downloadProgressValue(
                        processedCount: processedCount,
                        totalCount: totalCount
                    )
                )
            }

            // Handle inline user lists (paste/file imports) - load from local storage
            if filter.isInlineUserList {
                if let cachedContent = Self.loadRawFilterContent(
                    filterID: filterID
                ),
                    !cachedContent.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                {
                    let sourceRules = FilterListHeaderParser.countRules(
                        in: cachedContent
                    )
                    downloadedFilters.append(
                        (
                            filterID: filterID,
                            filter: filter,
                            content: cachedContent,
                            sourceRules: sourceRules
                        )
                    )
                    appendRules(cachedContent, to: &combinedAdvancedInputChunks)
                    filtersSkipped += 1  // Count as "skipped" since no download
                } else {
                    errors.append("\(filter.name): Local content not found")
                }
                continue
            }

            let requestURL =
                shouldForceFreshDownloads
                ? Self.cacheBustingURL(from: url)
                : url
            let currentETag =
                shouldForceFreshDownloads
                ? nil
                : await manager.getETag(for: filterID)
            let currentLastModified =
                shouldForceFreshDownloads
                ? nil
                : await manager.getLastModified(for: filterID)

            let result = await manager.downloadFilter(
                filterID: filterID,
                url: requestURL,
                currentETag: currentETag,
                currentLastModified: currentLastModified
            )

            // Handle download errors
            if let error = result.error {
                if let filterIndex = filterLists.firstIndex(where: {
                    $0.id == filterID
                }) {
                    filterLists[filterIndex].lastError = error
                }
                errors.append("\(filter.name): \(error)")
                continue
            }

            let content: String
            if result.wasModified {
                // Server returned new content (200)
                guard let newContent = result.content,
                    !newContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                else {
                    errors.append(
                        "\(filter.name): Download succeeded but content was empty"
                    )
                    continue
                }
                content = newContent

                // Update stored conditional request headers
                await manager.setETag(result.etag, for: filterID)
                await manager.setLastModified(
                    result.lastModified,
                    for: filterID
                )

                filtersDownloaded += 1

                // Save raw filter content for caching
                await manager.saveRawFilterContent(content, filterID: filterID)

                // Extract and update metadata from filter header
                if let filterIndex = filterLists.firstIndex(where: {
                    $0.id == filterID
                }) {
                    let header = FilterListHeaderParser.parseHeader(
                        from: content
                    )
                    if let version = header.version {
                        filterLists[filterIndex].version = version
                    }
                    filterLists[filterIndex].lastUpdated = Date()
                }
            } else {
                // Server returned 304 Not Modified - use cached content
                filtersSkipped += 1

                if let cachedContent = await manager.getRawFilterContent(
                    filterID: filterID
                ) {
                    content = cachedContent
                } else {
                    // Cache miss - force re-download without conditional headers
                    logger.debug(
                        "Cache miss for \(filter.name), forcing re-download"
                    )
                    let fallbackURL =
                        shouldForceFreshDownloads
                        ? Self.cacheBustingURL(from: url)
                        : url
                    let forceResult = await manager.downloadFilter(
                        filterID: filterID,
                        url: fallbackURL,
                        currentETag: nil,
                        currentLastModified: nil
                    )
                    guard let forcedContent = forceResult.content,
                        !forcedContent.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    else {
                        errors.append(
                            "\(filter.name): Cache miss and re-download failed"
                        )
                        continue
                    }
                    content = forcedContent
                    await manager.setETag(forceResult.etag, for: filterID)
                    await manager.setLastModified(
                        forceResult.lastModified,
                        for: filterID
                    )
                    await manager.saveRawFilterContent(
                        content,
                        filterID: filterID
                    )
                    filtersDownloaded += 1
                    filtersSkipped -= 1
                }
            }

            // Count source rules for load balancing
            let sourceRules = await Self.runBackground {
                FilterListHeaderParser.countRules(in: content)
            }

            downloadedFilters.append(
                (
                    filterID: filterID, filter: filter, content: content,
                    sourceRules: sourceRules
                )
            )
            appendRules(content, to: &combinedAdvancedInputChunks)
        }

        // PHASE 2: Distribute filters across blockers using load balancing
        logger.debug(
            "Phase 2: Distributing \(downloadedFilters.count) filters across blockers"
        )

        let filterAssignments = downloadedFilters.map { item in
            FilterAssignmentInfo(
                filterID: item.filterID,
                estimatedRuleCount: item.sourceRules
            )
        }

        let distribution = await loadBalancer.distributeFilters(
            filterAssignments
        )

        // Build a lookup from filterID to downloaded content
        var contentByFilterID: [String: (content: String, sourceRules: Int)] =
            [:]
        for item in downloadedFilters {
            contentByFilterID[item.filterID] = (
                content: item.content, sourceRules: item.sourceRules
            )
        }

        // PHASE 3: Process each blocker
        logger.debug("Phase 3: Processing \(totalBlockersToProcess) blockers")

        for blocker in ContentBlockerCategory.allCases {
            let assignedFilters = distribution[blocker] ?? []
            let hasExistingRulesFile = Self.hasConvertedRulesFile(for: blocker)

            logger.debug(
                "Processing blocker\(blocker.rawValue): \(assignedFilters.count) assigned filters, hasExistingRulesFile=\(hasExistingRulesFile)"
            )

            if assignedFilters.isEmpty {
                // No filters assigned to this blocker
                if hasExistingRulesFile {
                    logger.debug(
                        "Clearing blocker\(blocker.rawValue) (no assigned filters)"
                    )
                    updateRefreshPhase(
                        .reloading(category: "blocker\(blocker.rawValue)")
                    )
                    await Self.runBackground {
                        Self.saveEmptyContentBlocker(for: blocker)
                    }
                    await Self.runBackground {
                        Self.reloadContentBlocker(for: blocker)
                    }
                    await loadBalancer.updateActualRuleCount(0, for: blocker)
                }
                categoriesProcessed += 1
                advanceRefreshProgress(
                    to: categoryProgressValue(
                        categoriesProcessed: categoriesProcessed,
                        totalCategories: totalBlockersToProcess
                    ),
                    duration: 0.3
                )
                continue
            }

            // Combine content from all assigned filters
            var combinedRulesParts: [String] = []
            for filterInfo in assignedFilters {
                if let data = contentByFilterID[filterInfo.filterID] {
                    combinedRulesParts.append(data.content)
                }
            }

            if combinedRulesParts.isEmpty {
                categoriesSkipped += 1
                categoriesProcessed += 1
                advanceRefreshProgress(
                    to: categoryProgressValue(
                        categoriesProcessed: categoriesProcessed,
                        totalCategories: totalBlockersToProcess
                    ),
                    duration: 0.3
                )
                continue
            }

            // Convert and save the combined rules for this blocker
            updateRefreshPhase(
                .converting(category: "blocker\(blocker.rawValue)")
            )

            let combinedRulesSnapshot = combinedRulesParts
            let combinedRules = await Self.runBackground {
                combinedRulesSnapshot.joined(separator: "\n")
            }
            let conversionStartTime = Date()
            let conversion = await Self.runBackground {
                Self.convertAndSaveRules(rules: combinedRules, blocker: blocker)
            }
            totalConversionTime += Date().timeIntervalSince(conversionStartTime)

            let ruleCount = conversion.rulesCount
            totalRulesConverted += ruleCount

            // Update load balancer with actual rule count
            await loadBalancer.updateActualRuleCount(ruleCount, for: blocker)

            // Update rule counts for filters assigned to this blocker
            if ruleCount > 0 {
                let totalSourceRules = assignedFilters.reduce(0) {
                    $0 + $1.estimatedRuleCount
                }
                for filterInfo in assignedFilters {
                    if let filterIndex = filterLists.firstIndex(where: {
                        $0.id == filterInfo.filterID
                    }) {
                        // Distribute actual rules proportionally based on source rules
                        if totalSourceRules > 0 {
                            let proportion =
                                Double(filterInfo.estimatedRuleCount)
                                / Double(totalSourceRules)
                            filterLists[filterIndex].ruleCount = Int(
                                Double(ruleCount) * proportion
                            )
                        } else {
                            filterLists[filterIndex].ruleCount =
                                ruleCount / assignedFilters.count
                        }
                    }
                }
            }

            // Reload the content blocker for this blocker
            updateRefreshPhase(
                .reloading(category: "blocker\(blocker.rawValue)")
            )
            let reloadStartTime = Date()
            await Self.runBackground {
                Self.reloadContentBlocker(for: blocker)
            }
            totalReloadTime += Date().timeIntervalSince(reloadStartTime)

            // Record which filters were applied to this blocker (for backward compatibility)
            let appliedFilterIDs = Set(assignedFilters.map { $0.filterID })
            await manager.setLastAppliedFilters(appliedFilterIDs, for: blocker)

            categoriesProcessed += 1
            advanceRefreshProgress(
                to: categoryProgressValue(
                    categoriesProcessed: categoriesProcessed,
                    totalCategories: totalBlockersToProcess
                ),
                duration: 0.3
            )
        }

        // Save load balancer state
        await loadBalancer.saveState()

        // Check for limit warnings
        let warnings = await loadBalancer.checkLimitWarnings()
        for warning in warnings {
            if warning.isExceeding {
                errors.append(
                    "Blocker\(warning.blocker.rawValue) exceeds Safari limit: \(warning.count)/\(LoadBalancer.ruleLimit) rules"
                )
            } else {
                logger.warning(
                    "Blocker\(warning.blocker.rawValue) approaching limit: \(warning.count)/\(LoadBalancer.ruleLimit) rules"
                )
            }
        }

        updateRefreshPhase(.buildingEngine)
        advanceRefreshProgress(
            to: Constants.refreshBuildProgress,
            duration: 0.3
        )

        if enabledFilters.isEmpty {
            logger.debug(
                "No enabled filters - clearing advanced blocking engine"
            )
            await Self.runBackground {
                ContentBlockerService.rebuildAdvancedBlockingEngine(
                    groupIdentifier: GroupIdentifier.shared.value
                )
            }
        } else if !combinedAdvancedInputChunks.isEmpty {
            logger.debug(
                "Building advanced blocking engine with \(combinedAdvancedInputChunks.count) input chunks"
            )
            let advancedInputSnapshot = combinedAdvancedInputChunks
            let combinedAdvancedInputRules = await Self.runBackground {
                advancedInputSnapshot.joined(separator: "\n")
            }
            let advancedRules = await Self.runBackground {
                ContentBlockerService.extractAdvancedRules(
                    from: combinedAdvancedInputRules
                )
            }
            logger.debug(
                "Extracted \(advancedRules.count) chars of advanced rules"
            )
            await Self.runBackground {
                ContentBlockerService.rebuildAdvancedBlockingEngine(
                    groupIdentifier: GroupIdentifier.shared.value,
                    advancedRules: advancedRules
                )
            }
        } else {
            logger.debug(
                "No advanced input rules collected - skipping engine rebuild"
            )
        }

        advanceRefreshProgress(
            to: Constants.refreshFinalizingProgress,
            duration: 0.25
        )

        // Save all metadata after refresh completes
        saveMetadata()

        // Save the total converted rules for main UI display
        saveTotalConvertedRules(totalRulesConverted)

        // Calculate final statistics
        let totalDuration = Date().timeIntervalSince(overallStartTime)
        refreshStatistics = RefreshStatistics(
            totalRulesConverted: totalRulesConverted,
            categoriesProcessed: categoriesProcessed,
            filtersDownloaded: filtersDownloaded,
            filtersSkipped: filtersSkipped,
            categoriesSkipped: categoriesSkipped,
            conversionDuration: totalConversionTime,
            reloadDuration: totalReloadTime,
            totalDuration: totalDuration,
            errors: errors
        )

        advanceRefreshProgress(to: 1.0, duration: 0.35)
        try? await Task.sleep(for: Constants.refreshCompletionDelay)
        updateRefreshPhase(.completed(refreshStatistics))

        isRefreshing = false
        hasUnappliedChanges = false
    }

    /// Dismisses the refresh sheet
    func dismissRefreshSheet() {
        showRefreshSheet = false
        refreshPhase = .preparing
        refreshProgress = 0
    }

    /// Downloads filter list content from a URL
    private nonisolated func downloadFilterList(from url: URL) async throws
        -> String
    {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw FilterListError.downloadFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }

        let content = await Self.runBackground {
            String(data: data, encoding: .utf8)
        }
        guard let content else {
            throw FilterListError.downloadFailed("Invalid encoding")
        }

        return content
    }

    /// Converts AdGuard rules and saves to the shared app group container
    private nonisolated static func convertAndSaveRules(
        rules: String,
        category: FilterCategory
    ) -> ContentBlockerService.FilterConversionResult {
        ContentBlockerService.convertFilterWithAdvancedRules(
            rules: rules,
            groupIdentifier: GroupIdentifier.shared.value,
            rulesFilename: category.rulesFilename,
            buildAdvancedEngine: false
        )
    }

    private func appendRules(
        _ rules: String,
        to combinedRules: inout String
    ) {
        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !combinedRules.isEmpty {
            combinedRules.append("\n")
        }
        combinedRules.append(rules)
    }

    private func appendRules(
        _ rules: String,
        to combinedRules: inout [String]
    ) {
        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        combinedRules.append(rules)
    }

    /// Saves an empty content blocker JSON for a category (clears all rules)
    private nonisolated static func saveEmptyContentBlocker(
        for category: FilterCategory
    ) {
        // Safari requires at least one valid rule - use a dummy rule that matches nothing
        // Using ignore-previous-rules with a non-existent domain effectively disables blocking
        let emptyBlockerJSON = """
            [{"trigger": {"url-filter": ".*","if-domain": ["example.invalid"]},"action":{"type": "ignore-previous-rules"}}]
            """
        logger.debug("Saving empty content blocker for \(category.rawValue)")
        _ = ContentBlockerService.saveContentBlocker(
            jsonRules: emptyBlockerJSON,
            groupIdentifier: GroupIdentifier.shared.value,
            rulesFilename: category.rulesFilename
        )
    }

    /// Reloads a Safari content blocker extension
    private nonisolated static func reloadContentBlocker(
        for category: FilterCategory
    ) {
        logger.debug("Reloading content blocker for \(category.rawValue)")
        let result = ContentBlockerService.reloadContentBlocker(
            withIdentifier: category.contentBlockerIdentifier
        )

        switch result {
        case .success:
            logger.debug(
                "Successfully reloaded \(category.rawValue) content blocker"
            )
        case .failure(let error):
            logger.error(
                "Failed to reload \(category.rawValue) content blocker: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Load Balancing Helpers

    /// Returns the file URL for a blocker's converted rules
    private nonisolated static func rulesFileURL(
        for blocker: ContentBlockerCategory
    ) -> URL? {
        appGroupURL?.appendingPathComponent(blocker.rulesPath)
    }

    /// Checks if the converted JSON rules file exists for a blocker
    private nonisolated static func hasConvertedRulesFile(
        for blocker: ContentBlockerCategory
    ) -> Bool {
        guard let fileURL = Self.rulesFileURL(for: blocker) else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Converts AdGuard rules and saves to the shared app group container for a specific blocker
    private nonisolated static func convertAndSaveRules(
        rules: String,
        blocker: ContentBlockerCategory
    ) -> ContentBlockerService.FilterConversionResult {
        ContentBlockerService.convertFilterWithAdvancedRules(
            rules: rules,
            groupIdentifier: GroupIdentifier.shared.value,
            rulesFilename: blocker.rulesPath,
            buildAdvancedEngine: false
        )
    }

    /// Saves an empty content blocker JSON for a blocker (clears all rules)
    private nonisolated static func saveEmptyContentBlocker(
        for blocker: ContentBlockerCategory
    ) {
        let emptyBlockerJSON = """
            [{"trigger": {"url-filter": ".*","if-domain": ["example.invalid"]},"action":{"type": "ignore-previous-rules"}}]
            """
        logger.debug(
            "Saving empty content blocker for blocker\(blocker.rawValue)"
        )
        _ = ContentBlockerService.saveContentBlocker(
            jsonRules: emptyBlockerJSON,
            groupIdentifier: GroupIdentifier.shared.value,
            rulesFilename: blocker.rulesPath
        )
    }

    /// Reloads a Safari content blocker extension for a specific blocker
    private nonisolated static func reloadContentBlocker(
        for blocker: ContentBlockerCategory
    ) {
        logger.debug("Reloading content blocker for blocker\(blocker.rawValue)")
        let result = ContentBlockerService.reloadContentBlocker(
            withIdentifier: ContentBlockerIdentifier.identifier(for: blocker)
        )

        switch result {
        case .success:
            logger.debug(
                "Successfully reloaded blocker\(blocker.rawValue) content blocker"
            )
        case .failure(let error):
            logger.error(
                "Failed to reload blocker\(blocker.rawValue) content blocker: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @Bindable var viewModel: FilterListViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if os(macOS)
            NavigationSplitView {
                List(AppTab.allCases, selection: selectedTabBinding) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
                .listStyle(.sidebar)
            } detail: {
                NavigationStack {
                    tabContent
                        .navigationTitle(viewModel.selectedTab.rawValue)
                        .toolbar {
                            if viewModel.selectedTab == .filters {
                                ToolbarItemGroup(placement: .primaryAction) {
                                    toolbarButtons
                                }
                            }
                        }
                }
            }
            .frame(
                minWidth: 520,
                idealWidth: 640,
                minHeight: 560,
                idealHeight: 720
            )
            .sheet(isPresented: $viewModel.showAddCustomFilterSheet) {
                AddCustomFilterSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showRefreshSheet) {
                RefreshProgressSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showEnableContentBlockersSheet) {
                EnableContentBlockersSheet(viewModel: viewModel)
            }
            .overlay {
                autoUpdateOverlay
            }
            .onAppear {
                viewModel.startAutoUpdatePolling()
                refreshContentBlockerEnablementState()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                refreshContentBlockerEnablementState()
            }
            .onDisappear {
                viewModel.stopAutoUpdatePolling()
            }
        #else
            TabView(selection: $viewModel.selectedTab) {
                filtersTab
                    .tabItem {
                        Label(
                            AppTab.filters.rawValue,
                            systemImage: AppTab.filters.icon
                        )
                    }
                    .tag(AppTab.filters)

                settingsTab
                    .tabItem {
                        Label(
                            AppTab.settings.rawValue,
                            systemImage: AppTab.settings.icon
                        )
                    }
                    .tag(AppTab.settings)
            }
            #if os(visionOS)
                .glassBackgroundEffect()
            #endif
            .sheet(isPresented: $viewModel.showAddCustomFilterSheet) {
                AddCustomFilterSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showRefreshSheet) {
                RefreshProgressSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showEnableContentBlockersSheet) {
                EnableContentBlockersSheet(viewModel: viewModel)
            }
            .overlay {
                autoUpdateOverlay
            }
            .onAppear {
                viewModel.startAutoUpdatePolling()
                refreshContentBlockerEnablementState()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                refreshContentBlockerEnablementState()
            }
            .onDisappear {
                viewModel.stopAutoUpdatePolling()
            }
        #endif
    }

    /// Overlay shown when automatic filter updates are running in the background
    @ViewBuilder
    private var autoUpdateOverlay: some View {
        if viewModel.isAutoUpdating {
            ZStack {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()

                AutoUpdateIndicator()
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)
            }
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(
                .easeInOut(duration: 0.25),
                value: viewModel.isAutoUpdating
            )
        }
    }

    @ViewBuilder
    private var toolbarButtons: some View {
        Button {
            Task {
                await viewModel.refreshFilters()
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(viewModel.isRefreshing)
        .accessibilityLabel("Refresh filter lists")

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.showEnabledOnly.toggle()
            }
        } label: {
            Image(
                systemName: viewModel.showEnabledOnly
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel("Show enabled lists only")
        .accessibilityValue(viewModel.showEnabledOnly ? "On" : "Off")

        Button {
            viewModel.showAddCustomFilterSheet = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add custom filter")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .filters:
            FiltersView(viewModel: viewModel)
        case .settings:
            SettingsTabView()
        }
    }

    private var selectedTabBinding: Binding<AppTab?> {
        Binding<AppTab?>(
            get: { viewModel.selectedTab },
            set: { newValue in
                if let tab = newValue {
                    viewModel.selectedTab = tab
                }
            }
        )
    }

    private func refreshContentBlockerEnablementState() {
        Task {
            await viewModel.refreshContentBlockerEnablementState()
        }
    }

    #if os(iOS) || os(visionOS)
        private var filtersTab: some View {
            NavigationStack {
                FiltersView(viewModel: viewModel)
                    .navigationTitle(AppTab.filters.rawValue)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 8) {
                                toolbarButtons
                            }
                        }
                    }
                    #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
        }

        private var settingsTab: some View {
            NavigationStack {
                SettingsTabView()
                    .navigationTitle(AppTab.settings.rawValue)
                    #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
        }
    #endif
}

// MARK: - Content Blocker Enablement Sheet

struct EnableContentBlockersSheet: View {
    @Bindable var viewModel: FilterListViewModel
    @Environment(\.dismiss) private var dismiss

    private var disabledBlockersDescription: String {
        guard !viewModel.disabledContentBlockerNumbers.isEmpty else {
            return "None"
        }
        return viewModel.disabledContentBlockerNumbers
            .map(String.init)
            .joined(separator: ", ")
    }

    private var platformTitle: String {
        #if os(macOS)
            "macOS setup"
        #elseif os(visionOS)
            "visionOS setup"
        #else
            "iOS and iPadOS setup"
        #endif
    }

    private var platformInstructions: [String] {
        #if os(macOS)
            return [
                "Open Safari.",
                "Go to Safari > Settings > Extensions.",
                "Select WebShield and enable content blockers 1-9.",
                "Return to WebShield and tap Recheck.",
            ]
        #elseif os(visionOS)
            return [
                "Open Settings.",
                "Go to Apps > Safari > Extensions > Content Blockers.",
                "Enable WebShield content blockers 1-9.",
                "Return to WebShield and tap Recheck.",
            ]
        #else
            return [
                "Open Settings.",
                "Go to Safari > Extensions > Content Blockers.",
                "Enable WebShield content blockers 1-9.",
                "Return to WebShield and tap Recheck.",
            ]
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shield.slash.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Enable WebShield Content Blockers")
                        .font(.title3.weight(.semibold))
                    Text(
                        "WebShield requires all Safari content blockers (1-9) to be enabled."
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Text("Currently disabled: \(disabledBlockersDescription)")
                .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 10) {
                Text(platformTitle)
                    .font(.headline)

                ForEach(
                    Array(platformInstructions.enumerated()),
                    id: \.offset
                ) { step in
                    Text("\(step.offset + 1). \(step.element)")
                }
                .font(.subheadline)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Dismiss") {
                    dismiss()
                }

                Spacer()

                Button {
                    Task {
                        await viewModel.refreshContentBlockerEnablementState()
                    }
                } label: {
                    if viewModel.isCheckingContentBlockerStates {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Recheck")
                    }
                }
                .disabled(viewModel.isCheckingContentBlockerStates)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 320, idealHeight: 380)
        .background(Color.adaptiveBackground)
    }
}

// MARK: - Filters View

struct FiltersView: View {
    @Bindable var viewModel: FilterListViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isRegionalExpanded = false

    private var horizontalPadding: CGFloat {
        #if os(macOS)
            return 20
        #else
            return horizontalSizeClass == .compact ? 16 : 20
        #endif
    }

    /// Pre-computed category sections to avoid repeated O(n) filtering per
    /// category during view updates.
    private var visibleCategorySections:
        [(category: FilterCategory, filters: [FilterList])]
    {
        FilterCategory.displayOrder.compactMap { category in
            let filters = viewModel.filterLists(for: category)
            return filters.isEmpty ? nil : (category, filters)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 24) {
                    // Stats Header
                    StatsHeaderView(
                        enabledCount: viewModel.enabledListsCount,
                        rulesCount: viewModel.totalRulesFormatted
                    )

                    // Filter Categories
                    ForEach(visibleCategorySections, id: \.category) {
                        section in
                        FilterCategorySection(
                            category: section.category,
                            filters: section.filters,
                            isExpanded: section.category == .regional
                                ? $isRegionalExpanded : nil,
                            onToggle: { filter, isEnabled in
                                viewModel.setFilterEnabled(
                                    filter,
                                    isEnabled: isEnabled
                                )
                            },
                            onDelete: { filter in
                                viewModel.deleteCustomFilter(filter)
                            }
                        )
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
            }
            .scrollContentBackground(.hidden)
        }
        .searchable(
            text: $viewModel.searchText,
            placement: .automatic,
            prompt: "Search filters"
        )
        .background(Color.adaptiveBackground)
    }
}

// MARK: - Refresh Progress Sheet

struct RefreshProgressSheet: View {
    @Bindable var viewModel: FilterListViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var isCompleted: Bool {
        viewModel.refreshPhase.isCompleted
    }

    private var statistics: RefreshStatistics? {
        if case .completed(let stats) = viewModel.refreshPhase {
            return stats
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sheetHeader

            // Content
            ScrollView {
                VStack(spacing: 24) {
                    if isCompleted {
                        completedContent
                            .transition(
                                .opacity.combined(with: .move(edge: .bottom))
                            )
                    } else {
                        progressContent
                            .transition(
                                .opacity.combined(with: .move(edge: .top))
                            )
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isCompleted)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }

            // Footer
            if isCompleted {
                footerButtons
            }
        }
        .frame(minWidth: 400, idealWidth: 440, minHeight: 380, idealHeight: 420)
        .background(Color.adaptiveBackground)
        .interactiveDismissDisabled(!isCompleted)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(isCompleted ? "Refresh Complete" : "Refreshing Filters")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(.regularMaterial)
    }

    // MARK: - Progress Content

    private var progressContent: some View {
        VStack(spacing: 28) {
            // Animated icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.15), .cyan.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .cyan.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: phaseIcon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse, options: .repeating)
            }

            // Phase text
            VStack(spacing: 8) {
                Text(viewModel.refreshPhase.displayText)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(
                        .easeInOut(duration: 0.25),
                        value: viewModel.refreshPhase
                    )

                Text(phaseDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(
                        .easeInOut(duration: 0.25),
                        value: viewModel.refreshPhase
                    )
            }

            // Progress bar
            VStack(spacing: 10) {
                ProgressView(value: viewModel.refreshProgress)
                    .progressViewStyle(.linear)
                    .tint(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .scaleEffect(y: 1.5)
                    .animation(
                        .linear(duration: 0.25),
                        value: viewModel.refreshProgress
                    )

                Text("\(Int(viewModel.refreshProgress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(
                        .linear(duration: 0.2),
                        value: viewModel.refreshProgress
                    )
            }
            .padding(.horizontal, 20)

            stagesList
        }
        .padding(.top, 16)
    }

    private var phaseIcon: String {
        switch viewModel.refreshPhase {
        case .preparing:
            return "gear"
        case .downloading:
            return "arrow.down.circle"
        case .converting:
            return "doc.badge.gearshape"
        case .reloading:
            return "arrow.triangle.2.circlepath"
        case .buildingEngine:
            return "cpu"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var phaseDescription: String {
        switch viewModel.refreshPhase {
        case .preparing:
            return "Setting up the refresh stages..."
        case .downloading:
            return "Fetching filter lists from the internet"
        case .converting:
            return "Converting and saving rules to Safari format"
        case .reloading:
            return "Updating Safari content blockers"
        case .buildingEngine:
            return "Building advanced blocking engine"
        case .completed:
            return "All filters have been updated"
        case .failed:
            return "An error occurred during refresh"
        }
    }

    // MARK: - Stages

    private enum RefreshStage: Int, CaseIterable {
        case preparing
        case downloading
        case converting
        case reloading
        case building

        var title: String {
            switch self {
            case .preparing:
                return "Preparing"
            case .downloading:
                return "Downloading filters"
            case .converting:
                return "Converting and saving"
            case .reloading:
                return "Reloading blockers"
            case .building:
                return "Building engine"
            }
        }

        var detail: String {
            switch self {
            case .preparing:
                return "Checking enabled lists and cached rules"
            case .downloading:
                return "Fetching filter lists from sources"
            case .converting:
                return "Converting rules to Safari format"
            case .reloading:
                return "Reloading Safari content blockers"
            case .building:
                return "Building advanced blocking engine"
            }
        }
    }

    private enum RefreshStageState {
        case pending
        case active
        case completed

        var symbolName: String {
            switch self {
            case .pending:
                return "circle"
            case .active:
                return "circle.fill"
            case .completed:
                return "checkmark.circle.fill"
            }
        }

        var symbolColor: Color {
            switch self {
            case .pending:
                return .secondary
            case .active:
                return .blue
            case .completed:
                return .green
            }
        }
    }

    private var currentStage: RefreshStage {
        switch viewModel.refreshPhase {
        case .preparing:
            return .preparing
        case .downloading:
            return .downloading
        case .converting:
            return .converting
        case .reloading:
            return .reloading
        case .buildingEngine:
            return .building
        case .completed:
            return .building
        case .failed:
            return .preparing
        }
    }

    private func stageState(for stage: RefreshStage) -> RefreshStageState {
        if viewModel.refreshPhase.isCompleted {
            return .completed
        }

        let activeStage = currentStage
        if stage.rawValue < activeStage.rawValue {
            return .completed
        } else if stage.rawValue == activeStage.rawValue {
            return .active
        } else {
            return .pending
        }
    }

    private func stageDetail(
        for stage: RefreshStage,
        state: RefreshStageState
    ) -> String? {
        guard state == .active else { return stage.detail }

        switch viewModel.refreshPhase {
        case .preparing:
            return "Collecting enabled filters"
        case .downloading(let filterName, let current, let total):
            return "Downloading \(current) of \(total): \(filterName)"
        case .converting(let category):
            return "Converting and saving \(category) rules"
        case .reloading(let category):
            return "Reloading \(category)"
        case .buildingEngine:
            return "Building advanced engine"
        case .completed:
            return stage.detail
        case .failed:
            return "Stopped due to an error"
        }
    }

    private var stagesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stages")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(RefreshStage.allCases, id: \.self) { stage in
                    let state = stageState(for: stage)
                    StageRow(
                        title: stage.title,
                        detail: stageDetail(for: stage, state: state),
                        state: state
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.04)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.06),
                    lineWidth: 1
                )
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.refreshPhase)
    }

    private struct StageRow: View {
        let title: String
        let detail: String?
        let state: RefreshStageState

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.symbolColor)
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        value: state == .active
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(state == .active ? .semibold : .regular)
                        .foregroundStyle(
                            state == .pending ? .secondary : .primary
                        )

                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .opacity(state == .pending ? 0.7 : 1)
        }
    }

    // MARK: - Completed Content

    private var completedContent: some View {
        VStack(spacing: 24) {
            // Success icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.15), .mint.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.green, .mint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.bounce, value: isCompleted)
            }

            Text("Filters Updated Successfully")
                .font(.title3)
                .fontWeight(.semibold)

            // Statistics grid
            if let stats = statistics {
                statisticsGrid(stats)

                // Errors section if any
                if stats.hasErrors {
                    errorsSection(stats.errors)
                }
            }
        }
        .padding(.top, 8)
    }

    private func statisticsGrid(_ stats: RefreshStatistics) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(
                    icon: "shield.lefthalf.filled",
                    title: "Safari Rules",
                    value: formatNumber(stats.totalRulesConverted),
                    color: .blue
                )

                StatCard(
                    icon: "arrow.down.circle.fill",
                    title: "Downloaded",
                    value: "\(stats.filtersDownloaded)",
                    color: .green
                )
            }

            HStack(spacing: 12) {
                if stats.filtersSkipped > 0 {
                    StatCard(
                        icon: "checkmark.circle",
                        title: "Unchanged",
                        value: "\(stats.filtersSkipped)",
                        color: .secondary
                    )
                } else {
                    StatCard(
                        icon: "clock.fill",
                        title: "Total Time",
                        value: stats.formattedTotalDuration,
                        color: .orange
                    )
                }

                StatCard(
                    icon: "gearshape.fill",
                    title: "Conversion",
                    value: stats.formattedConversionDuration,
                    color: .purple
                )
            }

            // Show timing row if we showed "Unchanged" instead
            if stats.filtersSkipped > 0 {
                HStack(spacing: 12) {
                    StatCard(
                        icon: "clock.fill",
                        title: "Total Time",
                        value: stats.formattedTotalDuration,
                        color: .orange
                    )

                    Spacer()
                }
            }
        }
    }

    private func errorsSection(_ errors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                Text("\(errors.count) Warning\(errors.count > 1 ? "s" : "")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(errors.prefix(3), id: \.self) { error in
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if errors.count > 3 {
                    Text("and \(errors.count - 3) more...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        }
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    // MARK: - Footer

    private var footerButtons: some View {
        Button {
            viewModel.dismissRefreshSheet()
        } label: {
            Text("Done")
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.85)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.regularMaterial)
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.03)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.15), lineWidth: 1)
        }
    }
}

// MARK: - Stats Header View

struct StatsHeaderView: View {
    let enabledCount: Int
    let rulesCount: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            StatItemView(
                icon: "checklist",
                title: "Enabled Lists",
                value: "\(enabledCount)",
                color: .blue
            )

            Divider()
                .frame(height: 48)

            StatItemView(
                icon: "shield.lefthalf.filled",
                title: "Safari Rules",
                value: rulesCount,
                color: .green
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background {
            GlassBackground(cornerRadius: 16, showShadow: false)
        }
    }
}

struct StatItemView: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(color.gradient)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

// MARK: - Auto-Update Indicator

/// A high-emphasis indicator shown when automatic filter updates are running
/// in the background.
struct AutoUpdateIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = 36.0

    private var accentBackgroundOpacity: Double {
        colorScheme == .dark ? 0.26 : 0.12
    }

    private var accentBorderOpacity: Double {
        colorScheme == .dark ? 0.48 : 0.28
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        Color.accentColor.opacity(
                            colorScheme == .dark ? 0.32 : 0.18
                        )
                    )
                    .frame(width: iconSize, height: iconSize)

                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
                    #if os(macOS)
                        .scaleEffect(0.8)
                    #endif
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Automatic Filter List Update")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Downloading and applying updates in the background")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Label("Running", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            Color.accentColor.opacity(
                                colorScheme == .dark ? 0.24 : 0.14
                            )
                        )
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(accentBorderOpacity),
                            lineWidth: 1
                        )
                }
                .symbolEffect(.pulse.byLayer, options: .repeating)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            Color.accentColor.opacity(accentBackgroundOpacity)
                        )
                        .frame(width: 5)
                        .padding(.vertical, 2)
                        .padding(.leading, 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(
                                        accentBorderOpacity
                                    ),
                                    Color.accentColor.opacity(
                                        colorScheme == .dark ? 0.20 : 0.10
                                    ),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.12),
            radius: 10,
            x: 0,
            y: 4
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Automatic filter list update in progress"
        )
        .accessibilityHint(
            "WebShield is downloading and applying filter list updates."
        )
    }
}

// MARK: - Filter Category Section

struct FilterCategorySection: View {
    let category: FilterCategory
    let filters: [FilterList]
    var isExpanded: Binding<Bool>?
    let onToggle: (FilterList, Bool) -> Void
    var onDelete: ((FilterList) -> Void)?

    private var isCollapsible: Bool {
        isExpanded != nil
    }

    private var showContent: Bool {
        isExpanded?.wrappedValue ?? true
    }

    private var enabledCount: Int {
        filters.filter(\.isEnabled).count
    }

    /// Large sections (like Regional) get a lighter transition to keep
    /// expand/collapse interactions responsive on mobile devices.
    private var isLargeSection: Bool {
        filters.count >= 24
    }

    private var contentTransition: AnyTransition {
        if isLargeSection {
            return .identity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Category Header
            categoryHeader

            // Filter Cards
            if showContent {
                filterCards
                    .transition(contentTransition)
            }
        }
    }

    @ViewBuilder
    private var categoryHeader: some View {
        if isCollapsible {
            Button {
                if isLargeSection {
                    // Skip expand/collapse animation for very large sections.
                    isExpanded?.wrappedValue.toggle()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        isExpanded?.wrappedValue.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Label {
                        Text(category.rawValue)
                            .font(.headline)
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: category.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(category.color.gradient)
                    }

                    if !showContent && enabledCount > 0 {
                        Text("\(enabledCount) enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background {
                                Capsule()
                                    .fill(category.color.opacity(0.12))
                            }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showContent ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .accessibilityLabel(
                "\(category.rawValue), \(showContent ? "expanded" : "collapsed")"
            )
            .accessibilityHint(
                "Double tap to \(showContent ? "collapse" : "expand")"
            )
        } else {
            Label {
                Text(category.rawValue)
                    .font(.headline)
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(category.color.gradient)
            }
            .padding(.leading, 4)
        }
    }

    private var filterCards: some View {
        VStack(spacing: 0) {
            ForEach(filters) { filter in
                FilterListRowView(
                    filter: filter,
                    isEnabled: filter.isEnabled,
                    onToggle: { isEnabled in
                        onToggle(filter, isEnabled)
                    },
                    onDelete: filter.isCustomFilter
                        ? { onDelete?(filter) } : nil
                )

                if filter.id != filters.last?.id {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .background {
            GlassBackground(cornerRadius: 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Filter List Row View

struct FilterListRowView: View {
    let filter: FilterList
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    var onDelete: (() -> Void)?

    private var links: [FilterLink] {
        var items: [FilterLink] = []
        // Don't show "View Source" for inline user lists (paste/file imports)
        if let downloadURL = filter.downloadURL, !filter.isInlineUserList {
            items.append(
                FilterLink(
                    id: "view-source",
                    title: "View Source",
                    systemImage: "doc.plaintext",
                    url: downloadURL
                )
            )
        }
        if let homepageURL = filter.homepageURL {
            items.append(
                FilterLink(
                    id: "homepage",
                    title: "Homepage",
                    systemImage: "house",
                    url: homepageURL
                )
            )
        }
        if let informationURL = filter.informationURL {
            items.append(
                FilterLink(
                    id: "info",
                    title: "Info",
                    systemImage: "info.circle",
                    url: informationURL
                )
            )
        }
        return items
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Content
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(filter.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    if filter.isPending {
                        PendingBadge()
                    }
                }

                Text("\(filter.ruleCountFormatted) rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(filter.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !links.isEmpty {
                    FilterLinkBar(links: links)
                }

                Text("Version \(filter.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Spacer(minLength: 16)

            // Delete button for custom filters
            if let onDelete = onDelete, filter.isCustomFilter {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background {
                            Circle()
                                .fill(.red.opacity(0.1))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(filter.name)")
            }

            // Toggle
            Toggle(
                filter.name,
                isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in onToggle(newValue) }
                )
            )
            .labelsHidden()
            .tint(.accentColor)
            #if os(macOS)
                .toggleStyle(.switch)
                .controlSize(.regular)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contextMenu {
            if let onDelete = onDelete, filter.isCustomFilter {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Filter", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Supporting Views

private struct FilterLink: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let url: URL
}

private struct FilterLinkBar: View {
    let links: [FilterLink]
    @Environment(\.openURL) private var openURL

    var body: some View {
        ViewThatFits(in: .horizontal) {
            linkGroup(showText: true)
            linkGroup(showText: false)
        }
        .controlSize(controlSize)
    }

    private var controlSize: ControlSize {
        #if os(visionOS)
            return .large
        #elseif os(macOS)
            return .small
        #else
            return .regular
        #endif
    }

    @ViewBuilder
    private func linkGroup(showText: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(links) { link in
                Button {
                    openURL(link.url)
                } label: {
                    linkLabel(for: link, showText: showText)
                }
                .accessibilityLabel(link.title)
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func linkLabel(for link: FilterLink, showText: Bool) -> some View {
        if showText {
            Label(link.title, systemImage: link.systemImage)
        } else {
            Label(link.title, systemImage: link.systemImage)
                .labelStyle(.iconOnly)
        }
    }
}

struct PendingBadge: View {
    var body: some View {
        Text("Pending")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(.orange.opacity(0.15))
                    .overlay {
                        Capsule()
                            .strokeBorder(.orange.opacity(0.3), lineWidth: 0.5)
                    }
            }
    }
}

struct GlassBackground: View {
    let cornerRadius: CGFloat
    var showShadow: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .shadow(
                color: showShadow
                    ? (colorScheme == .dark
                        ? .black.opacity(0.3) : .black.opacity(0.08))
                    : .clear,
                radius: showShadow ? (colorScheme == .dark ? 12 : 8) : 0,
                x: 0,
                y: showShadow ? (colorScheme == .dark ? 4 : 2) : 0
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(
                                    colorScheme == .dark ? 0.15 : 0.5
                                ),
                                .white.opacity(
                                    colorScheme == .dark ? 0.05 : 0.2
                                ),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
    }
}

// MARK: - Settings Tab View

struct SettingsTabView: View {
    @StateObject private var autoUpdateViewModel = AutoUpdateSettingsViewModel()
    @State private var showDeveloperFilters: Bool = {
        let defaults =
            UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
        return defaults.bool(forKey: DeveloperSettingsKeys.showDeveloperFilters)
    }()
    @State private var forceManualRefreshDownloads: Bool = {
        let defaults =
            UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
        return defaults.bool(
            forKey: DeveloperSettingsKeys.forceManualRefreshDownloads
        )
    }()

    var body: some View {
        NavigationStack {
            Form {
                // Auto-Update Section
                Section {
                    Toggle(
                        "Automatic Updates",
                        isOn: Binding(
                            get: { autoUpdateViewModel.isEnabled },
                            set: { autoUpdateViewModel.setEnabled($0) }
                        )
                    )

                    if autoUpdateViewModel.isEnabled {
                        Picker(
                            "Update Interval",
                            selection: Binding(
                                get: { autoUpdateViewModel.intervalHours },
                                set: { autoUpdateViewModel.setInterval($0) }
                            )
                        ) {
                            Text("Every hour").tag(1.0)
                            Text("Every 3 hours").tag(3.0)
                            Text("Every 6 hours").tag(6.0)
                            Text("Every 12 hours").tag(12.0)
                            Text("Every 24 hours").tag(24.0)
                        }
                    }
                } header: {
                    Text("Filter Updates")
                } footer: {
                    if autoUpdateViewModel.isEnabled {
                        if let lastUpdate = autoUpdateViewModel
                            .lastSuccessfulTime
                        {
                            Text(
                                "Last updated: \(lastUpdate.formatted(date: .abbreviated, time: .shortened))"
                            )
                        } else {
                            Text(
                                "Filters will update automatically in the background"
                            )
                        }
                    } else {
                        Text(
                            "Enable to keep filter lists updated automatically"
                        )
                    }
                }

                // Update Progress Section (shown during/after update)
                if !autoUpdateViewModel.updatePhase.isIdle {
                    Section {
                        InlineUpdateProgressView(viewModel: autoUpdateViewModel)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 12,
                                    leading: 16,
                                    bottom: 12,
                                    trailing: 16
                                )
                            )
                            .listRowBackground(Color.clear)
                    }
                }

                // Update Status Section (when auto-update is enabled)
                if autoUpdateViewModel.isEnabled {
                    Section("Update Status") {
                        if autoUpdateViewModel.isAutoUpdateRunning {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating filters…")
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(
                                        with: .move(edge: .top)
                                    ),
                                    removal: .opacity
                                )
                            )
                        }

                        HStack {
                            Text("Last Check")
                            Spacer()
                            if let lastCheck = autoUpdateViewModel.lastCheckTime
                            {
                                Text(
                                    lastCheck.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                                .foregroundStyle(.secondary)
                            } else {
                                Text("Never")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Text("Next Scheduled")
                            Spacer()
                            if autoUpdateViewModel.isAutoUpdateRunning {
                                Text("Updating now")
                                    .foregroundStyle(.blue)
                                    .font(.subheadline)
                            } else if autoUpdateViewModel.isOverdue {
                                Label(
                                    "Overdue",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                            } else if let nextTime = autoUpdateViewModel
                                .nextScheduledTime
                            {
                                Text(
                                    nextTime.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                                .foregroundStyle(.secondary)
                            } else {
                                Text("Not scheduled")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .animation(
                        .easeInOut(duration: 0.3),
                        value: autoUpdateViewModel.isAutoUpdateRunning
                    )
                } else {
                    // Manual update button when auto-update is disabled
                    // Section {
                    //     Button {
                    //         autoUpdateViewModel.triggerManualUpdate()
                    //     } label: {
                    //         HStack {
                    //             Label(
                    //                 "Update Filters Now",
                    //                 systemImage: "arrow.clockwise"
                    //             )
                    //             Spacer()
                    //             if autoUpdateViewModel.isUpdating {
                    //                 ProgressView()
                    //                     .controlSize(.small)
                    //             }
                    //         }
                    //     }
                    //     .disabled(autoUpdateViewModel.isUpdating)
                    // } header: {
                    //     Text("Manual Update")
                    // } footer: {
                    //     Text("Check for and download filter list updates")
                    // }
                }

                // Trusted Sites Section
                Section {
                    NavigationLink {
                        WhitelistView()
                    } label: {
                        Label("Trusted Sites", systemImage: "checkmark.shield")
                    }
                } header: {
                    Text("Site Management")
                } footer: {
                    Text("Disable ad blocking for specific websites")
                }

                Section {
                    NavigationLink {
                        LogsView()
                    } label: {
                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("View application logs for troubleshooting")
                }

                Section {
                    Toggle(
                        "Show Developer Filters",
                        isOn: $showDeveloperFilters
                    )
                    .onChange(of: showDeveloperFilters) { _, newValue in
                        let defaults =
                            UserDefaults(
                                suiteName: GroupIdentifier.shared.value
                            ) ?? .standard
                        defaults.set(
                            newValue,
                            forKey: DeveloperSettingsKeys.showDeveloperFilters
                        )
                    }

                    Toggle(
                        "Force Fresh Downloads on Refresh",
                        isOn: $forceManualRefreshDownloads
                    )
                    .onChange(of: forceManualRefreshDownloads) { _, newValue in
                        let defaults =
                            UserDefaults(
                                suiteName: GroupIdentifier.shared.value
                            ) ?? .standard
                        defaults.set(
                            newValue,
                            forKey:
                                DeveloperSettingsKeys
                                .forceManualRefreshDownloads
                        )
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text(
                        "Developer options for testing: show experimental filters and force toolbar refreshes to bypass ETag/Last-Modified cache checks."
                    )
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(
                            Bundle.main.infoDictionary?[
                                "CFBundleShortVersionString"
                            ] as? String ?? "1.0"
                        )
                        .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text(
                            Bundle.main.infoDictionary?["CFBundleVersion"]
                                as? String ?? "1"
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                #if DEBUG
                    DebugSettingsSection()
                #endif
            }
            .navigationTitle("Settings")
            #if os(macOS)
                .formStyle(.grouped)
            #endif
            .onAppear {
                autoUpdateViewModel.refresh()
                autoUpdateViewModel.startPolling()
            }
            .onDisappear {
                autoUpdateViewModel.stopPolling()
            }
        }
    }
}

// MARK: - Debug Settings Section

#if DEBUG
    /// Debug-only settings section for testing auto-update UI and other features
    struct DebugSettingsSection: View {
        @State private var isSimulatingAutoUpdate = false
        @State private var simulationDuration: Double = 5

        var body: some View {
            Section {
                Toggle("Simulate Auto-Update", isOn: $isSimulatingAutoUpdate)
                    .onChange(of: isSimulatingAutoUpdate) { _, newValue in
                        if newValue {
                            startSimulatedAutoUpdate()
                        } else {
                            stopSimulatedAutoUpdate()
                        }
                    }

                if isSimulatingAutoUpdate {
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(Int(simulationDuration))s")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $simulationDuration, in: 2...30, step: 1)
                }

                Button {
                    triggerTimedSimulation()
                } label: {
                    HStack {
                        Label(
                            "Test Auto-Update Indicator",
                            systemImage: "play.circle"
                        )
                        Spacer()
                        Text("\(Int(simulationDuration))s")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isSimulatingAutoUpdate)
            } header: {
                Label("Debug", systemImage: "ladybug")
            } footer: {
                Text(
                    "Simulates an auto-update to test the indicator UI. The indicator should appear at the top of the screen."
                )
            }
        }

        private func startSimulatedAutoUpdate() {
            Task {
                await FilterUpdateManager.shared.setDebugRunningState(true)
            }
        }

        private func stopSimulatedAutoUpdate() {
            Task {
                await FilterUpdateManager.shared.setDebugRunningState(false)
            }
        }

        private func triggerTimedSimulation() {
            isSimulatingAutoUpdate = true
            Task {
                try? await Task.sleep(for: .seconds(simulationDuration))
                await MainActor.run {
                    isSimulatingAutoUpdate = false
                }
            }
        }
    }
#endif

// MARK: - Update Phase Enum

/// Represents the current phase of an update operation in settings
enum UpdatePhase: Equatable {
    case idle
    case preparing
    case downloading(filterName: String, current: Int, total: Int)
    case converting(category: String)
    case reloading(category: String)
    case buildingEngine
    case completed(UpdateStatistics)
    case failed(String)

    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .preparing:
            return "Preparing update..."
        case .downloading(let name, let current, let total):
            return "Downloading \(name) (\(current)/\(total))"
        case .converting(let category):
            return "Converting \(category) rules..."
        case .reloading(let category):
            return "Reloading \(category)..."
        case .buildingEngine:
            return "Building advanced engine..."
        case .completed:
            return "Update complete"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isInProgress: Bool {
        switch self {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var icon: String {
        switch self {
        case .idle:
            return "arrow.clockwise"
        case .preparing:
            return "gear"
        case .downloading:
            return "arrow.down.circle"
        case .converting:
            return "doc.badge.gearshape"
        case .reloading:
            return "arrow.triangle.2.circlepath"
        case .buildingEngine:
            return "cpu"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    static func == (lhs: UpdatePhase, rhs: UpdatePhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.preparing, .preparing):
            return true
        case (
            .downloading(let n1, let c1, let t1),
            .downloading(let n2, let c2, let t2)
        ):
            return n1 == n2 && c1 == c2 && t1 == t2
        case (.converting(let c1), .converting(let c2)):
            return c1 == c2
        case (.reloading(let c1), .reloading(let c2)):
            return c1 == c2
        case (.buildingEngine, .buildingEngine):
            return true
        case (.completed, .completed):
            return true
        case (.failed(let e1), .failed(let e2)):
            return e1 == e2
        default:
            return false
        }
    }
}

/// Statistics for a completed update operation
struct UpdateStatistics {
    var filtersChecked: Int = 0
    var filtersUpdated: Int = 0
    var rulesConverted: Int = 0
    var blockersReloaded: Int = 0
    var duration: TimeInterval = 0
    var errors: [String] = []

    var hasErrors: Bool { !errors.isEmpty }

    var formattedDuration: String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1f s", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
}

// MARK: - Auto-Update Settings ViewModel

@MainActor
final class AutoUpdateSettingsViewModel: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var intervalHours: Double = 6.0
    @Published var lastCheckTime: Date?
    @Published var lastSuccessfulTime: Date?
    @Published var nextScheduledTime: Date?
    @Published var isOverdue: Bool = false

    // Background auto-update running state
    @Published var isAutoUpdateRunning: Bool = false
    private var autoUpdatePollingTask: Task<Void, Never>?

    // Progress tracking
    @Published var updatePhase: UpdatePhase = .idle
    @Published var updateProgress: Double = 0
    @Published var updateStatistics = UpdateStatistics()

    // Dismissal timer for completed state
    private var completedDismissTask: Task<Void, Never>?

    var isUpdating: Bool {
        updatePhase.isInProgress
    }

    init() {
        refresh()
    }

    func refresh() {
        Task {
            let manager = FilterUpdateManager.shared
            let status = await manager.getStatus()

            self.isEnabled = status.isEnabled
            self.intervalHours = status.intervalHours
            self.lastCheckTime = status.lastCheckTime
            self.lastSuccessfulTime = status.lastSuccessfulTime
            self.nextScheduledTime = status.nextScheduledTime
            self.isOverdue = status.isOverdue
            self.isAutoUpdateRunning = status.isRunning
        }
    }

    /// Starts polling for background auto-update running state
    func startPolling() {
        autoUpdatePollingTask?.cancel()
        autoUpdatePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAutoUpdateStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops polling for background auto-update running state
    func stopPolling() {
        autoUpdatePollingTask?.cancel()
        autoUpdatePollingTask = nil
    }

    private func pollAutoUpdateStatus() async {
        let status = await FilterUpdateManager.shared.getStatus()
        let wasRunning = isAutoUpdateRunning
        if isAutoUpdateRunning != status.isRunning {
            withAnimation(.easeInOut(duration: 0.3)) {
                isAutoUpdateRunning = status.isRunning
            }
        }
        // When auto-update just finished, refresh all status fields
        if wasRunning && !status.isRunning {
            self.lastCheckTime = status.lastCheckTime
            self.lastSuccessfulTime = status.lastSuccessfulTime
            self.nextScheduledTime = status.nextScheduledTime
            self.isOverdue = status.isOverdue
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        Task {
            await FilterUpdateManager.shared.setAutoUpdateEnabled(enabled)
            FilterUpdateScheduler.shared.scheduleBackgroundUpdates()
            // Refresh immediately so "Next Scheduled" updates after toggling.
            refresh()
        }
    }

    func setInterval(_ hours: Double) {
        self.intervalHours = hours
        Task {
            await FilterUpdateManager.shared.setUpdateIntervalHours(hours)
            FilterUpdateScheduler.shared.scheduleBackgroundUpdates()
            // Refresh to show updated nextScheduledTime
            refresh()
        }
    }

    func triggerManualUpdate() {
        // Cancel any pending dismissal
        completedDismissTask?.cancel()
        completedDismissTask = nil

        updatePhase = .preparing
        updateProgress = 0
        updateStatistics = UpdateStatistics()

        Task {
            await performDetailedUpdate()
        }
    }

    func dismissCompletedState() {
        withAnimation(.easeOut(duration: 0.3)) {
            updatePhase = .idle
            updateProgress = 0
        }
    }

    private func performDetailedUpdate() async {
        let startTime = Date()
        let manager = FilterUpdateManager.shared
        let logger = WebShieldLogger.shared
        let logCategory = "Updates"

        // Load enabled filters
        let filters = await FilterUpdateHandler.loadEnabledFilters()

        guard !filters.isEmpty else {
            await MainActor.run {
                withAnimation {
                    updatePhase = .failed("No enabled filters to update")
                }
            }
            scheduleCompletedDismissal()
            return
        }

        let totalFilters = filters.count
        var downloadedCount = 0
        var updatedCount = 0
        var rulesCount = 0
        var blockersCount = 0
        var errors: [String] = []

        // Track downloaded content for load balancing
        var downloadedContent: [String: String] = [:]
        var sourceRulesByFilter: [String: Int] = [:]

        // Download filters with progress
        await MainActor.run {
            withAnimation {
                updatePhase = .downloading(
                    filterName: "filters",
                    current: 0,
                    total: totalFilters
                )
                updateProgress = 0.05
            }
        }

        let downloadResults = await manager.downloadFilters(filters: filters)

        for result in downloadResults {
            downloadedCount += 1

            await MainActor.run {
                let filterName =
                    result.filterID.components(separatedBy: "-").last
                    ?? result.filterID
                withAnimation(.linear(duration: 0.15)) {
                    updatePhase = .downloading(
                        filterName: filterName,
                        current: downloadedCount,
                        total: totalFilters
                    )
                    updateProgress =
                        0.05 + (Double(downloadedCount) / Double(totalFilters))
                        * 0.35
                }
            }

            if let error = result.error {
                errors.append("Failed to download \(result.filterID): \(error)")
                continue
            }

            if result.wasModified, let content = result.content {
                updatedCount += 1

                // Save metadata
                if let etag = result.etag {
                    await manager.setETag(etag, for: result.filterID)
                }
                if let lastModified = result.lastModified {
                    await manager.setLastModified(
                        lastModified,
                        for: result.filterID
                    )
                }
                await manager.saveRawFilterContent(
                    content,
                    filterID: result.filterID
                )

                downloadedContent[result.filterID] = content
                // Count source rules for load balancing
                sourceRulesByFilter[result.filterID] =
                    content.components(separatedBy: .newlines)
                    .filter {
                        !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[")
                    }.count
            }
        }

        // Also load cached content for filters that weren't modified
        for filter in filters {
            if downloadedContent[filter.id] == nil,
                let content = FilterUpdateHandler.loadRawFilterContent(
                    filterID: filter.id
                )
            {
                downloadedContent[filter.id] = content
                sourceRulesByFilter[filter.id] =
                    content.components(separatedBy: .newlines)
                    .filter {
                        !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[")
                    }.count
            }
        }

        // Use load balancer to distribute filters across blockers
        let loadBalancer = LoadBalancer.shared
        await loadBalancer.loadState()

        let filterAssignments = downloadedContent.map { (filterID, _) in
            FilterAssignmentInfo(
                filterID: filterID,
                estimatedRuleCount: sourceRulesByFilter[filterID] ?? 0
            )
        }
        let distribution = await loadBalancer.distributeFilters(
            filterAssignments
        )

        // Process each blocker with assigned filters
        let blockersToProcess = ContentBlockerCategory.allCases.filter {
            blocker in
            !(distribution[blocker]?.isEmpty ?? true)
        }
        var processedBlockers = 0

        for blocker in blockersToProcess {
            guard let assignedFilters = distribution[blocker],
                !assignedFilters.isEmpty
            else { continue }

            // Combine content from assigned filters
            var combinedContent = ""
            for filterInfo in assignedFilters {
                if let content = downloadedContent[filterInfo.filterID] {
                    combinedContent += content + "\n"
                }
            }

            guard !combinedContent.isEmpty else { continue }

            // Converting phase
            await MainActor.run {
                withAnimation(.linear(duration: 0.15)) {
                    updatePhase = .converting(
                        category: String(blocker.rawValue)
                    )
                    updateProgress =
                        0.4
                        + (Double(processedBlockers)
                            / Double(blockersToProcess.count)) * 0.25
                }
            }

            let conversionResult =
                ContentBlockerService.convertFilterWithAdvancedRules(
                    rules: combinedContent,
                    groupIdentifier: GroupIdentifier.shared.value,
                    rulesFilename: blocker.rulesFilename,
                    buildAdvancedEngine: false
                )
            rulesCount += conversionResult.rulesCount
            await loadBalancer.updateActualRuleCount(
                conversionResult.rulesCount,
                for: blocker
            )

            // Reloading phase
            await MainActor.run {
                withAnimation(.linear(duration: 0.15)) {
                    updatePhase = .reloading(category: String(blocker.rawValue))
                    updateProgress =
                        0.65
                        + (Double(processedBlockers)
                            / Double(blockersToProcess.count)) * 0.2
                }
            }

            let reloadResult = ContentBlockerService.reloadContentBlocker(
                withIdentifier: ContentBlockerIdentifier.identifier(
                    for: blocker
                )
            )

            switch reloadResult {
            case .success:
                blockersCount += 1
                logger.debug(
                    "Reloaded content blocker for blocker\(blocker.rawValue)",
                    category: logCategory
                )
            case .failure(let error):
                errors.append(
                    "Failed to reload blocker\(blocker.rawValue): \(error.localizedDescription)"
                )
            }

            processedBlockers += 1
        }

        // Save load balancer state
        await loadBalancer.saveState()

        // Build advanced engine if we updated anything
        if updatedCount > 0 {
            await MainActor.run {
                withAnimation(.linear(duration: 0.15)) {
                    updatePhase = .buildingEngine
                    updateProgress = 0.85
                }
            }

            await FilterUpdateHandler.rebuildAdvancedEngine(filters: filters)
        }

        // Complete
        let duration = Date().timeIntervalSince(startTime)

        await MainActor.run {
            let stats = UpdateStatistics(
                filtersChecked: totalFilters,
                filtersUpdated: updatedCount,
                rulesConverted: rulesCount,
                blockersReloaded: blockersCount,
                duration: duration,
                errors: errors
            )
            updateStatistics = stats

            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                updatePhase = .completed(stats)
                updateProgress = 1.0
            }
        }

        // Update last successful time
        await manager.setLastSuccessfulTimeNow()

        // Refresh displayed times
        refresh()

        // Schedule auto-dismissal
        scheduleCompletedDismissal()
    }

    private func scheduleCompletedDismissal() {
        completedDismissTask?.cancel()
        completedDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                if updatePhase.isCompleted || updatePhase.isFailed {
                    updatePhase = .idle
                    updateProgress = 0
                }
            }
        }
    }
}

// MARK: - Inline Update Progress View

struct InlineUpdateProgressView: View {
    @ObservedObject var viewModel: AutoUpdateSettingsViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var statistics: UpdateStatistics? {
        if case .completed(let stats) = viewModel.updatePhase {
            return stats
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.updatePhase.isInProgress {
                progressContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(
                                with: .scale(scale: 0.95)
                            ),
                            removal: .opacity
                        )
                    )
            } else if viewModel.updatePhase.isCompleted {
                completedContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(
                                with: .scale(scale: 0.95)
                            ),
                            removal: .opacity
                        )
                    )
            } else if viewModel.updatePhase.isFailed {
                failedContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(
                                with: .scale(scale: 0.95)
                            ),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.8),
            value: viewModel.updatePhase
        )
    }

    // MARK: - Progress Content

    private var progressContent: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                // Animated progress ring
                ZStack {
                    Circle()
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.1)
                                : Color.black.opacity(0.08),
                            lineWidth: 4
                        )
                        .frame(width: 44, height: 44)

                    Circle()
                        .trim(from: 0, to: viewModel.updateProgress)
                        .stroke(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                        .animation(
                            .linear(duration: 0.2),
                            value: viewModel.updateProgress
                        )

                    Image(systemName: viewModel.updatePhase.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.pulse, options: .repeating)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.updatePhase.displayText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    Text("\(Int(viewModel.updateProgress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                Spacer()
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.1)
                                : Color.black.opacity(0.08)
                        )

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: geometry.size.width
                                * viewModel.updateProgress
                        )
                        .animation(
                            .linear(duration: 0.2),
                            value: viewModel.updateProgress
                        )
                }
            }
            .frame(height: 6)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .blue.opacity(colorScheme == .dark ? 0.15 : 0.08),
                            .cyan.opacity(colorScheme == .dark ? 0.1 : 0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.blue.opacity(0.3), .cyan.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Completed Content

    private var completedContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .green.opacity(0.2), .mint.opacity(0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.green, .mint],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(
                            .bounce,
                            value: viewModel.updatePhase.isCompleted
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Complete")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    if let stats = statistics {
                        Text(
                            "\(stats.filtersUpdated) filter\(stats.filtersUpdated == 1 ? "" : "s") updated in \(stats.formattedDuration)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    viewModel.dismissCompletedState()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Stats row
            if let stats = statistics, stats.filtersUpdated > 0 {
                HStack(spacing: 16) {
                    StatPill(
                        icon: "arrow.down.circle.fill",
                        value: "\(stats.filtersUpdated)",
                        label: "Updated",
                        color: .green
                    )

                    StatPill(
                        icon: "shield.fill",
                        value: formatCompactNumber(stats.rulesConverted),
                        label: "Rules",
                        color: .blue
                    )

                    if stats.blockersReloaded > 0 {
                        StatPill(
                            icon: "arrow.triangle.2.circlepath",
                            value: "\(stats.blockersReloaded)",
                            label: "Reloaded",
                            color: .purple
                        )
                    }
                }
            }

            // Errors if any
            if let stats = statistics, stats.hasErrors {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(
                        "\(stats.errors.count) warning\(stats.errors.count == 1 ? "" : "s")"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .green.opacity(colorScheme == .dark ? 0.15 : 0.08),
                            .mint.opacity(colorScheme == .dark ? 0.1 : 0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.green.opacity(0.3), .mint.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Failed Content

    private var failedContent: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.red.opacity(0.2), .orange.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.red, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Update Failed")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                if case .failed(let error) = viewModel.updatePhase {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button {
                viewModel.dismissCompletedState()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .red.opacity(colorScheme == .dark ? 0.15 : 0.08),
                            .orange.opacity(colorScheme == .dark ? 0.1 : 0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.red.opacity(0.3), .orange.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Helpers

    private func formatCompactNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return "\(number)"
    }
}

// MARK: - Stat Pill Component

private struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)

            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.05)
                )
        }
    }
}

// MARK: - Logs View

struct LogsView: View {
    private let logStore = WebShieldLogStore.shared
    @State private var searchText = ""
    @State private var selectedLevel: LogLevel?
    @State private var selectedCategory: String?
    @State private var isLoading = true
    @State private var showingClearConfirmation = false

    private var availableCategories: [String] {
        Array(Set(logStore.entries.map(\.category))).sorted()
    }

    private var filteredLogs: [LogEntry] {
        logStore.entries.filter { entry in
            let matchesSearch =
                searchText.isEmpty
                || entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.category.localizedCaseInsensitiveContains(searchText)
                || entry.level.displayName.localizedCaseInsensitiveContains(
                    searchText
                )
            let matchesLevel =
                selectedLevel == nil || entry.level == selectedLevel
            let matchesCategory =
                selectedCategory == nil || entry.category == selectedCategory
            return matchesSearch && matchesLevel && matchesCategory
        }
    }

    private var hasActiveFilters: Bool {
        selectedCategory != nil || selectedLevel != nil || !searchText.isEmpty
    }

    var body: some View {
        Group {
            #if os(macOS)
                macOSLayout
            #else
                iOSLayout
            #endif
        }
        .navigationTitle("Activity")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
        #endif
        .searchable(text: $searchText, prompt: "Search logs")
        .toolbar {
            toolbarContent
        }
        .task {
            await refreshLogs()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await refreshLogs()
            }
        }
        .refreshable {
            await refreshLogs()
        }
        .confirmationDialog(
            "Clear All Logs",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task { await logStore.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all log entries.")
        }
    }

    // MARK: - Platform Layouts

    #if os(macOS)
        private var macOSLayout: some View {
            HSplitView {
                sidebarContent
                    .frame(minWidth: 180, idealWidth: 180, maxWidth: 200)

                mainContent
                    .frame(minWidth: 400)
            }
        }
    #endif

    #if os(iOS) || os(visionOS)
        private var iOSLayout: some View {
            List {
                if !availableCategories.isEmpty {
                    filterSection
                }

                if isLoading {
                    loadingSection
                } else if logStore.entries.isEmpty {
                    emptyStateSection
                } else if filteredLogs.isEmpty {
                    noResultsSection
                } else {
                    logsListSection
                }
            }
            .listStyle(.insetGrouped)
        }
    #endif

    // MARK: - macOS Sidebar

    #if os(macOS)
        private var sidebarContent: some View {
            List {
                Section("Categories") {
                    sidebarRow(
                        title: "All Activity",
                        icon: "list.bullet.rectangle",
                        color: .secondary,
                        isSelected: selectedCategory == nil
                    ) {
                        selectedCategory = nil
                    }

                    ForEach(availableCategories, id: \.self) { category in
                        sidebarRow(
                            title: LogCategoryInfo.displayName(for: category),
                            icon: LogCategoryInfo.icon(for: category),
                            color: LogCategoryInfo.color(for: category),
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }

                Section("Filter by Level") {
                    Picker("Level", selection: $selectedLevel) {
                        Text("All Levels").tag(nil as LogLevel?)
                        Divider()
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Label(level.displayName, systemImage: level.icon)
                                .tag(level as LogLevel?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if hasActiveFilters {
                    Section {
                        Button {
                            withAnimation {
                                selectedCategory = nil
                                selectedLevel = nil
                                searchText = ""
                            }
                        } label: {
                            Label(
                                "Clear All Filters",
                                systemImage: "xmark.circle"
                            )
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }

        private func sidebarRow(
            title: String,
            icon: String,
            color: Color,
            isSelected: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack {
                    Label(title, systemImage: icon)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(isSelected ? .white : color)
            .buttonStyle(.plain)
            .listRowBackground(
                isSelected
                    ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                    : nil
            )
        }
    #endif

    // MARK: - macOS Main Content

    #if os(macOS)
        private var mainContent: some View {
            Group {
                if isLoading {
                    loadingView
                } else if logStore.entries.isEmpty {
                    emptyStateView
                } else if filteredLogs.isEmpty {
                    noResultsView
                } else {
                    logsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }

        private var logsList: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredLogs) { entry in
                        LogEntryRow(entry: entry)
                        Divider()
                    }
                }
            }
        }
    #endif

    // MARK: - iOS List Sections

    #if os(iOS) || os(visionOS)
        private var filterSection: some View {
            Section {
                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(nil as String?)
                    ForEach(availableCategories, id: \.self) { category in
                        Label(
                            LogCategoryInfo.displayName(for: category),
                            systemImage: LogCategoryInfo.icon(for: category)
                        )
                        .tag(category as String?)
                    }
                }

                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(nil as LogLevel?)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Label(level.displayName, systemImage: level.icon)
                            .tag(level as LogLevel?)
                    }
                }

                if hasActiveFilters {
                    Button {
                        withAnimation {
                            selectedCategory = nil
                            selectedLevel = nil
                            searchText = ""
                        }
                    } label: {
                        Label("Clear Filters", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Filters")
            }
        }

        private var loadingSection: some View {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading activity...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }

        private var emptyStateSection: some View {
            Section {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.badge.questionmark",
                    description: Text(
                        "Activity logs will appear here as WebShield protects your browsing."
                    )
                )
                .listRowBackground(Color.clear)
            }
        }

        private var noResultsSection: some View {
            Section {
                ContentUnavailableView.search(
                    text: searchText.isEmpty ? "filters" : searchText
                )
                .listRowBackground(Color.clear)
            }
        }

        private var logsListSection: some View {
            Section {
                ForEach(filteredLogs) { entry in
                    LogEntryRow(entry: entry)
                }
            } header: {
                HStack {
                    Text("\(filteredLogs.count) entries")
                    Spacer()
                    if let latest = filteredLogs.first {
                        Text("Latest: \(latest.date, style: .relative) ago")
                    }
                }
                .font(.caption)
                .textCase(nil)
            }
        }
    #endif

    // MARK: - macOS States

    #if os(macOS)
        private var loadingView: some View {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading activity...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }

        private var emptyStateView: some View {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "clock.badge.questionmark",
                description: Text(
                    "Activity logs will appear here as WebShield protects your browsing."
                )
            )
        }

        private var noResultsView: some View {
            ContentUnavailableView.search(
                text: searchText.isEmpty ? "filters" : searchText
            )
        }
    #endif

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !filteredLogs.isEmpty {
                ShareLink(item: exportLogsAsText()) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }

            Menu {
                if hasActiveFilters {
                    Button {
                        withAnimation {
                            selectedCategory = nil
                            selectedLevel = nil
                            searchText = ""
                        }
                    } label: {
                        Label(
                            "Clear Filters",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                    Divider()
                }

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear All Logs", systemImage: "trash")
                }
                .disabled(logStore.entries.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }

        #if os(macOS)
            ToolbarItem(placement: .automatic) {
                if !filteredLogs.isEmpty {
                    Text("\(filteredLogs.count) entries")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        #endif
    }

    // MARK: - Helpers

    private func exportLogsAsText() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        return filteredLogs.map { entry in
            "[\(dateFormatter.string(from: entry.date))] [\(entry.level.displayName.uppercased())] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private func refreshLogs() async {
        await logStore.refreshFromDisk()
        isLoading = false
    }
}

// MARK: - Log Category Info

private enum LogCategoryInfo {
    static func displayName(for category: String) -> String {
        switch category {
        case "Updates": return "Updates"
        case "ContentBlocker": return "Content Blocker"
        case "Whitelist": return "Whitelist"
        case "WebExtension": return "Web Extension"
        default: return category
        }
    }

    static func icon(for category: String) -> String {
        switch category {
        case "Updates": return "arrow.triangle.2.circlepath"
        case "ContentBlocker": return "shield.lefthalf.filled"
        case "Whitelist": return "checkmark.circle"
        case "WebExtension": return "puzzlepiece.extension"
        default: return "tag"
        }
    }

    static func color(for category: String) -> Color {
        switch category {
        case "Updates": return .orange
        case "ContentBlocker": return .blue
        case "Whitelist": return .green
        case "WebExtension": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var formattedTime: String {
        entry.date.formatted(date: .omitted, time: .standard)
    }

    private var relativeTime: String {
        entry.date.formatted(.relative(presentation: .named))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                // Level indicator
                levelBadge

                // Category
                Text(entry.category)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                // Timestamp
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                #if os(iOS)
                    // Expansion indicator for iOS
                    Image(
                        systemName: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                #endif
            }

            // Message
            Text(entry.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if entry.message.count > 80 {
                            withAnimation(.snappy(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        }
                    }
                #endif
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        #if os(iOS)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
        #endif
        .contextMenu {
            contextMenuContent
        }
        #if os(macOS)
            .background(rowBackground)
        #endif
    }

    private var levelBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: entry.level.icon)
                .font(.system(size: 9, weight: .semibold))

            Text(entry.level.displayName)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(badgeForegroundColor)
        .background(entry.level.color.opacity(0.15), in: Capsule())
    }

    private var badgeForegroundColor: Color {
        switch entry.level {
        case .error, .fault:
            return entry.level.color
        case .warning:
            return .orange
        default:
            return entry.level.color
        }
    }

    #if os(macOS)
        private var rowBackground: some View {
            Group {
                if entry.level == .error || entry.level == .fault {
                    entry.level.color.opacity(0.05)
                } else if entry.level == .warning {
                    Color.orange.opacity(0.03)
                } else {
                    Color.clear
                }
            }
        }
    #endif

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            copyToClipboard(entry.message)
        } label: {
            Label("Copy Message", systemImage: "doc.on.doc")
        }

        Button {
            let fullLog =
                "[\(entry.date.formatted())] [\(entry.level.displayName)] [\(entry.category)] \(entry.message)"
            copyToClipboard(fullLog)
        } label: {
            Label("Copy Full Entry", systemImage: "doc.on.doc.fill")
        }

        Divider()

        Button {
            copyToClipboard(
                entry.date.formatted(date: .complete, time: .complete)
            )
        } label: {
            Label("Copy Timestamp", systemImage: "clock")
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Custom Filter Add Mode

enum CustomFilterAddMode: String, CaseIterable, Identifiable {
    case url = "URL"
    case paste = "Paste"
    case file = "File"
    var id: String { rawValue }
}

// MARK: - Add Custom Filter Sheet

struct AddCustomFilterSheet: View {
    @Bindable var viewModel: FilterListViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var focusedEntryID: UUID?
    @State private var addMode: CustomFilterAddMode = .url
    @State private var showingFileImporter = false

    /// Adaptive horizontal padding based on platform and size class
    private var horizontalPadding: CGFloat {
        #if os(iOS)
            return horizontalSizeClass == .compact ? 16 : 24
        #else
            return 24
        #endif
    }

    var body: some View {
        ZStack {
            // Background
            Color.adaptiveBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                sheetHeader

                // Content
                ScrollView {
                    VStack(spacing: 24) {
                        // Icon and description
                        headerSection

                        // Mode picker
                        modePickerSection

                        // Content based on mode
                        switch addMode {
                        case .url:
                            urlModeContent
                        case .paste:
                            pasteModeContent
                        case .file:
                            fileModeContent
                        }

                        // Error display
                        if let error = viewModel.addCustomFilterError {
                            errorSection(error)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }

                // Footer with buttons
                footerButtons
            }
        }
        #if os(macOS)
            .frame(
                minWidth: 480,
                idealWidth: 520,
                minHeight: 480,
                idealHeight: 560
            )
        #elseif os(visionOS)
            .frame(
                minWidth: 400,
                idealWidth: 480,
                minHeight: 400,
                idealHeight: 500
            )
        #endif
        .interactiveDismissDisabled(viewModel.isAddingCustomFilter)
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #endif
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Button {
                viewModel.resetCustomFilterForm()
                dismiss()
            } label: {
                Text("Cancel")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Text("Add Custom Filter")
                .font(.headline)

            Spacer()

            // Invisible spacer for centering
            Text("Cancel")
                .opacity(0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.2), .purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)

                Image(systemName: headerIcon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text(headerDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var headerIcon: String {
        switch addMode {
        case .url: return "link"
        case .paste: return "doc.on.clipboard"
        case .file: return "doc.badge.plus"
        }
    }

    private var headerDescription: String {
        switch addMode {
        case .url:
            return "Add a custom filter list by entering its URL."
        case .paste:
            return "Paste filter rules directly as text."
        case .file:
            return "Import filter rules from a local file."
        }
    }

    // MARK: - Mode Picker Section

    private var modePickerSection: some View {
        Picker("Input Method", selection: $addMode) {
            ForEach(CustomFilterAddMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: addMode) { _, _ in
            // Clear error when switching modes
            viewModel.addCustomFilterError = nil
        }
    }

    // MARK: - URL Mode Content

    private var urlModeContent: some View {
        VStack(spacing: 16) {
            // Name input (optional for URL mode)
            nameSection(placeholder: "Optional — uses filter's title if empty")

            // URL inputs
            urlSection
        }
    }

    // MARK: - Paste Mode Content

    private var pasteModeContent: some View {
        VStack(spacing: 16) {
            // Title input (required for paste mode)
            titleSection

            // Optional description
            descriptionSection

            // Rules text editor
            rulesSection
        }
    }

    // MARK: - File Mode Content

    private var fileModeContent: some View {
        VStack(spacing: 16) {
            // Title input (required for file mode)
            titleSection

            // Optional description
            descriptionSection

            // File picker button
            filePickerSection
        }
    }

    // MARK: - Name Section (for URL mode)

    private func nameSection(placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)

                TextField(
                    placeholder,
                    text: $viewModel.customFilterName
                )
                .textFieldStyle(.plain)
                #if os(iOS)
                    .textContentType(.name)
                #endif
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.black.opacity(0.04)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    // MARK: - Title Section (for Paste/File modes)

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "textformat")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)

                TextField(
                    "Filter list name (required)",
                    text: $viewModel.customFilterTitle
                )
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.black.opacity(0.04)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)

                TextField(
                    "Optional description",
                    text: $viewModel.customFilterDescription
                )
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.black.opacity(0.04)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    // MARK: - Rules Section (for Paste mode)

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filter Rules")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                if !viewModel.customFilterPastedRules.isEmpty {
                    let lineCount = viewModel.customFilterPastedRules
                        .components(separatedBy: .newlines)
                        .filter {
                            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                        }
                        .count
                    Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            TextEditor(text: $viewModel.customFilterPastedRules)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150, maxHeight: 250)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.06)
                                : Color.black.opacity(0.04)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }

            // Footer text
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                Text("Paste AdBlock-style filter rules, one per line.")
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
    }

    // MARK: - File Picker Section

    private var filePickerSection: some View {
        let hasTitleForFile = !viewModel.customFilterTitle
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            Text("Filter File")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Button {
                showingFileImporter = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 20))
                        .foregroundStyle(hasTitleForFile ? .blue : .gray)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose File")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(
                            hasTitleForFile
                                ? "Select a .txt file containing filter rules"
                                : "Enter a title first"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.06)
                                : Color.black.opacity(0.04)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasTitleForFile ? .primary : .secondary)
            .disabled(!hasTitleForFile)

            // Footer text
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                Text("Supports plain text files with AdBlock-style rules.")
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
    }

    // MARK: - URL Section

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter List URL")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach($viewModel.customFilterURLEntries) { $entry in
                    let entryID = entry.id
                    URLInputRowView(
                        entry: $entry,
                        entryCount: viewModel.customFilterURLEntries.count,
                        focusedEntryID: $focusedEntryID,
                        onPaste: { pasteFromClipboard(into: $entry) },
                        onRemove: {
                            // Defer removal to avoid simultaneous access conflict
                            Task { @MainActor in
                                withAnimation(.spring(duration: 0.25)) {
                                    viewModel.customFilterURLEntries.removeAll {
                                        $0.id == entryID
                                    }
                                }
                            }
                        },
                        onClear: { entry.url = "" },
                        colorScheme: colorScheme
                    )
                }

                // Add another URL button
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        let newEntry = URLInputEntry()
                        viewModel.customFilterURLEntries.append(newEntry)
                        focusedEntryID = newEntry.id
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                        Text("Add Another URL")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.blue.opacity(0.08))
                    }
                }
                .buttonStyle(.plain)
            }

            // Footer text
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                Text(
                    "~~WebShield will download and enable the filter automatically.~~ NO IT WONT, YOU NEED TO REFRESH MANUALLY"
                )
                .font(.caption)
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.red)

            Text(error)
                .font(.subheadline)
                .foregroundStyle(.red)

            Spacer()
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
        }
    }

    // MARK: - Footer Buttons

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.resetCustomFilterForm()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)

            Button {
                addFilter()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isAddingCustomFilter {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                    Text(addButtonText)
                        .font(.body)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            hasValidInput && !viewModel.isAddingCustomFilter
                                ? LinearGradient(
                                    colors: [.blue, .blue.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                : LinearGradient(
                                    colors: [
                                        .gray.opacity(0.5), .gray.opacity(0.4),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                        )
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(!hasValidInput || viewModel.isAddingCustomFilter)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 20)
        .background(.regularMaterial)
    }

    private var addButtonText: String {
        if viewModel.isAddingCustomFilter {
            return "Adding..."
        }
        switch addMode {
        case .url:
            return "Add Filter"
        case .paste:
            return "Add Filter"
        case .file:
            return "Choose File"
        }
    }

    // MARK: - Helpers

    private var hasValidInput: Bool {
        switch addMode {
        case .url:
            return hasValidURL
        case .paste:
            let title = viewModel.customFilterTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let rules = viewModel.customFilterPastedRules.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return !title.isEmpty && !rules.isEmpty
        case .file:
            let title = viewModel.customFilterTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return !title.isEmpty
        }
    }

    private var hasValidURL: Bool {
        viewModel.customFilterURLEntries.contains { entry in
            let trimmed = entry.url.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let parsed = URL(string: trimmed) else { return false }
            return parsed.scheme == "http" || parsed.scheme == "https"
        }
    }

    private func pasteFromClipboard(into entry: Binding<URLInputEntry>) {
        #if os(iOS)
            if let string = UIPasteboard.general.string {
                entry.wrappedValue.url = string
            }
        #elseif os(macOS)
            if let string = NSPasteboard.general.string(forType: .string) {
                entry.wrappedValue.url = string
            }
        #endif
    }

    private func addFilter() {
        switch addMode {
        case .url:
            addURLFilter()
        case .paste:
            addPastedFilter()
        case .file:
            showingFileImporter = true
        }
    }

    private func addURLFilter() {
        Task {
            do {
                let urls = viewModel.customFilterURLEntries.map(\.url)
                try await viewModel.addCustomFilter(
                    urls: urls,
                    name: viewModel.customFilterName.isEmpty
                        ? nil : viewModel.customFilterName
                )
                viewModel.resetCustomFilterForm()
                dismiss()
            } catch {
                viewModel.addCustomFilterError = error.localizedDescription
            }
        }
    }

    private func addPastedFilter() {
        Task {
            do {
                let description =
                    viewModel.customFilterDescription.isEmpty
                    ? nil : viewModel.customFilterDescription
                try await viewModel.addUserList(
                    name: viewModel.customFilterTitle,
                    description: description,
                    content: viewModel.customFilterPastedRules
                )
                viewModel.resetCustomFilterForm()
                dismiss()
            } catch {
                viewModel.addCustomFilterError = error.localizedDescription
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            Task {
                do {
                    let description =
                        viewModel.customFilterDescription.isEmpty
                        ? nil : viewModel.customFilterDescription
                    try await viewModel.addUserListFromFile(
                        fileURL: fileURL,
                        title: viewModel.customFilterTitle,
                        description: description
                    )
                    viewModel.resetCustomFilterForm()
                    dismiss()
                } catch {
                    viewModel.addCustomFilterError = error.localizedDescription
                }
            }
        case .failure(let error):
            viewModel.addCustomFilterError = error.localizedDescription
        }
    }
}

// MARK: - URL Input Row View

private struct URLInputRowView: View {
    @Binding var entry: URLInputEntry
    let entryCount: Int
    @Binding var focusedEntryID: UUID?
    let onPaste: () -> Void
    let onRemove: () -> Void
    let onClear: () -> Void
    let colorScheme: ColorScheme
    @FocusState private var isFocused: Bool

    private var isMultiple: Bool { entryCount > 1 }
    private var showActionButton: Bool { !entry.url.isEmpty || isMultiple }

    private var actionButtonIcon: String {
        isMultiple ? "trash" : "xmark"
    }

    private var actionButtonColor: Color {
        isMultiple ? .red : .secondary
    }

    private var actionButtonBackground: Color {
        isMultiple ? Color.red.opacity(0.1) : Color.primary.opacity(0.06)
    }

    private var backgroundFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var borderColor: Color {
        isFocused ? Color.blue.opacity(0.5) : Color.primary.opacity(0.08)
    }

    private var borderWidth: CGFloat {
        isFocused ? 2 : 1
    }

    var body: some View {
        HStack(spacing: 10) {
            linkIcon
            urlTextField
            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .onChange(of: focusedEntryID) { _, newValue in
            isFocused = newValue == entry.id
        }
        .onChange(of: isFocused) { _, newValue in
            if newValue {
                focusedEntryID = entry.id
            }
        }
    }

    private var linkIcon: some View {
        Image(systemName: "link")
            .font(.system(size: 16))
            .foregroundStyle(.tertiary)
            .frame(width: 20)
    }

    private var urlTextField: some View {
        TextField("https://example.com/filters.txt", text: $entry.url)
            .textFieldStyle(.plain)
            .focused($isFocused)
            #if os(iOS)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocapitalization(.none)
            #endif
            .disableAutocorrection(true)
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            pasteButton

            if showActionButton {
                clearOrRemoveButton
            }
        }
    }

    private var pasteButton: some View {
        Button(action: onPaste) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .help("Paste from clipboard")
    }

    private var clearOrRemoveButton: some View {
        Button {
            if isMultiple {
                onRemove()
            } else {
                onClear()
            }
        } label: {
            Image(systemName: actionButtonIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(actionButtonColor)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(actionButtonBackground)
                }
        }
        .buttonStyle(.plain)
        .help(isMultiple ? "Remove" : "Clear")
    }
}

// MARK: - Whitelist View Model

@MainActor
@Observable
final class WhitelistViewModel {
    var whitelistedDomains: [String] = []
    var newDomain: String = ""
    var showingAddSheet = false
    var showingError = false
    var errorMessage: String = ""
    var isApplyingChanges = false

    init() {
        loadDomains()
    }

    func loadDomains() {
        whitelistedDomains = WhitelistManager.shared.whitelistedDomains
    }

    func addDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if WhitelistManager.shared.addDomain(trimmed) {
            newDomain = ""
            loadDomains()
            applyWhitelistChanges()
        } else {
            errorMessage = "Invalid domain or already whitelisted"
            showingError = true
        }
    }

    func removeDomain(_ domain: String) {
        WhitelistManager.shared.removeDomain(domain)
        loadDomains()
        applyWhitelistChanges()
    }

    func removeDomains(at offsets: IndexSet) {
        for index in offsets {
            let domain = whitelistedDomains[index]
            WhitelistManager.shared.removeDomain(domain)
        }
        loadDomains()
        applyWhitelistChanges()
    }

    func clearAllDomains() {
        WhitelistManager.shared.clearAllDomains()
        loadDomains()
        applyWhitelistChanges()
    }

    /// Applies whitelist changes by updating all content blockers
    private func applyWhitelistChanges() {
        isApplyingChanges = true

        Task {
            // Fast update whitelist rules in all content blocker categories
            for category in ContentBlockerCategory.allCases {
                _ = ContentBlockerService.fastUpdateWhitelist(
                    groupIdentifier: GroupIdentifier.shared.value,
                    rulesFilename: category.rulesPath
                )

                // Reload the content blocker
                _ = ContentBlockerService.reloadContentBlocker(
                    withIdentifier: ContentBlockerIdentifier.identifier(
                        for: category
                    )
                )
            }

            await MainActor.run {
                isApplyingChanges = false
            }

            logger.info("Whitelist changes applied to all content blockers")
        }
    }
}

// MARK: - Whitelist View

struct WhitelistView: View {
    @State private var viewModel = WhitelistViewModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if viewModel.whitelistedDomains.isEmpty
                && viewModel.newDomain.isEmpty
            {
                emptyStateView
            } else {
                domainListView
            }
        }
        .navigationTitle("Trusted Sites")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showingAddSheet = true
                } label: {
                    Label("Add Site", systemImage: "plus")
                }
            }

            if !viewModel.whitelistedDomains.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            viewModel.clearAllDomains()
                        } label: {
                            Label("Remove All", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showingAddSheet) {
            addDomainSheet
        }
        .alert("Error", isPresented: $viewModel.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .overlay {
            if viewModel.isApplyingChanges {
                applyingChangesOverlay
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Trusted Sites", systemImage: "checkmark.shield")
        } description: {
            Text(
                "Add websites here to disable ad blocking for them. Useful for sites that don't work correctly with blocking enabled."
            )
        } actions: {
            Button {
                viewModel.showingAddSheet = true
            } label: {
                Text("Add Trusted Site")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Domain List

    private var domainListView: some View {
        List {
            Section {
                ForEach(viewModel.whitelistedDomains, id: \.self) { domain in
                    HStack {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        Text(domain)
                            .font(.body)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.removeDomain(domain)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.removeDomain(domain)
                        } label: {
                            Label(
                                "Remove from Trusted Sites",
                                systemImage: "trash"
                            )
                        }

                        Button {
                            #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    domain,
                                    forType: .string
                                )
                            #else
                                UIPasteboard.general.string = domain
                            #endif
                        } label: {
                            Label("Copy Domain", systemImage: "doc.on.doc")
                        }
                    }
                }
                .onDelete(perform: viewModel.removeDomains)
            } header: {
                Text("Trusted Sites")
            } footer: {
                Text(
                    "Ad blocking is disabled on these sites. Both the domain and all subdomains are trusted."
                )
            }
        }
        #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
        #else
            .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Add Domain Sheet

    private var addDomainSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)

                        TextField("example.com", text: $viewModel.newDomain)
                            #if os(iOS)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .onSubmit {
                                if !viewModel.newDomain.isEmpty {
                                    viewModel.addDomain()
                                    viewModel.showingAddSheet = false
                                }
                            }
                    }
                } header: {
                    Text("Domain")
                } footer: {
                    Text(
                        "Enter a domain like 'example.com'. Both the domain and all its subdomains will be trusted."
                    )
                }
            }
            .navigationTitle("Add Trusted Site")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.newDomain = ""
                        viewModel.showingAddSheet = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        viewModel.addDomain()
                        viewModel.showingAddSheet = false
                    }
                    .disabled(
                        viewModel.newDomain.trimmingCharacters(in: .whitespaces)
                            .isEmpty
                    )
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 200)
        #endif
    }

    // MARK: - Applying Changes Overlay

    private var applyingChangesOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)

                Text("Applying changes...")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(24)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
    }
}

// MARK: - Color Extension for Cross-Platform Support

extension Color {
    static var adaptiveBackground: Color {
        #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
        #elseif os(visionOS)
            return Color.clear
        #else
            return Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var adaptiveSecondaryBackground: Color {
        #if os(macOS)
            return Color(nsColor: .controlBackgroundColor)
        #elseif os(visionOS)
            return Color.clear
        #else
            return Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .primary
        case .warning: return .orange
        case .error: return .red
        case .fault: return .indigo
        @unknown default: return .primary
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(viewModel: FilterListViewModel())
}

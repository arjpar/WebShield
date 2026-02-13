//
//  AppDelegate.swift
//  WebShield
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import WebShieldService
import UserNotifications

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

extension Notification.Name {
    static let applyWebShieldChangesNotification = Notification.Name(
        "applyWebShieldChangesNotification"
    )
}

// MARK: - Filter Update Handler

/// Standalone handler for filter updates to avoid Sendable issues
enum FilterUpdateHandler {

    private static let logger = WebShieldLogger.shared
    private static let logCategory = "Updates"

    /// Perform the actual filter update using load balancing
    static func performFilterUpdate(force: Bool, trigger: String) async {
        let manager = FilterUpdateManager.shared
        let loadBalancer = LoadBalancer.shared

        // Use shared log for cross-process visibility
        await manager.appendSharedLog(
            "Update triggered: \(trigger), force: \(force)"
        )

        // Ensure content blocker directory structure exists
        ContentBlockerService.ensureDirectoryStructure(
            groupIdentifier: GroupIdentifier.shared.value
        )

        // Load previous load balancer state
        await loadBalancer.loadState()

        // Get enabled filters from UserDefaults
        let filters = await loadEnabledFilters()

        guard !filters.isEmpty else {
            await manager.appendSharedLog("No enabled filters to update")
            return
        }

        let shouldRunUpdate = await manager.shouldRunUpdate(force: force)
        guard shouldRunUpdate else {
            await manager.appendSharedLog(
                "Skipped update trigger '\(trigger)' (not eligible)"
            )
            return
        }

        // Keep UI indicator active for the entire auto-update pipeline:
        // download -> conversion -> save -> reload -> engine rebuild.
        await manager.setUpdatePipelineActive(true)
        defer {
            Task {
                await manager.setUpdatePipelineActive(false)
            }
        }

        // Collector for downloaded content
        let contentCollector = FilterContentCollector()

        // Run the update to download filters
        let result = await manager.maybeRunAutoUpdate(
            filters: filters,
            force: force,
            onFilterUpdated: { filterID in
                Task {
                    await manager.appendSharedLog("Downloaded: \(filterID)")
                }
            }
        )

        if let result = result {
            let durationFormatted = String(format: "%.1f", result.duration)
            await manager.appendSharedLog(
                "Completed: \(result.filtersUpdated)/\(result.filtersChecked) in \(durationFormatted)s"
            )

            // Log partial failure with retry info
            if result.hadPartialFailure, let retryIn = result.retryScheduledIn {
                await manager.appendSharedLog(
                    "Partial failure - retry scheduled in \(Int(retryIn))s"
                )
            }

            // Log errors
            for error in result.errors {
                await manager.appendSharedLog("Error: \(error)")
            }

            // Collect downloaded filter content with rule counts
            for filter in filters {
                if let content = loadRawFilterContent(filterID: filter.id) {
                    let sourceRules = countRules(in: content)
                    await contentCollector.add(
                        filterID: filter.id,
                        content: content,
                        sourceRules: sourceRules
                    )
                }
            }

            // Get collected content
            let downloadedFilters = await contentCollector.getAll()

            if !downloadedFilters.isEmpty {
                // Distribute filters across blockers using load balancing
                let filterAssignments = downloadedFilters.map { item in
                    FilterAssignmentInfo(
                        filterID: item.filterID,
                        estimatedRuleCount: item.sourceRules
                    )
                }
                let distribution = await loadBalancer.distributeFilters(
                    filterAssignments
                )

                // Build lookup for content
                var contentByFilterID: [String: String] = [:]
                for item in downloadedFilters {
                    contentByFilterID[item.filterID] = item.content
                }

                // Process each blocker
                for blocker in ContentBlockerCategory.allCases {
                    let assignedFilters = distribution[blocker] ?? []

                    if assignedFilters.isEmpty {
                        // Check if this blocker previously had rules
                        if hasConvertedRulesFile(for: blocker) {
                            await processBlocker(blocker: blocker, content: nil)
                            await loadBalancer.updateActualRuleCount(
                                0,
                                for: blocker
                            )
                        }
                        continue
                    }

                    // Combine content from assigned filters
                    var combinedContent = ""
                    for filterInfo in assignedFilters {
                        if let content = contentByFilterID[filterInfo.filterID]
                        {
                            if !combinedContent.isEmpty {
                                combinedContent += "\n"
                            }
                            combinedContent += content
                        }
                    }

                    if !combinedContent.isEmpty {
                        let ruleCount = await processBlocker(
                            blocker: blocker,
                            content: combinedContent
                        )
                        await loadBalancer.updateActualRuleCount(
                            ruleCount,
                            for: blocker
                        )

                        // Record applied filters
                        let appliedIDs = Set(
                            assignedFilters.map { $0.filterID }
                        )
                        await manager.setLastAppliedFilters(
                            appliedIDs,
                            for: blocker
                        )
                    }
                }

                // Save load balancer state
                await loadBalancer.saveState()

                // Log distribution summary
                let summary = await loadBalancer.getDistributionSummary()
                for assignment in summary where !assignment.filters.isEmpty {
                    await manager.appendSharedLog(
                        "Blocker\(assignment.blocker.rawValue): \(assignment.filters.count) filters, \(assignment.actualRuleCount ?? assignment.estimatedRuleCount) rules"
                    )
                }
            }

            // Rebuild advanced engine after all blockers are processed
            if result.filtersUpdated > 0 || !downloadedFilters.isEmpty {
                await rebuildAdvancedEngine(filters: filters)
            }
        }
    }

    /// Check if converted rules file exists for a blocker
    private static func hasConvertedRulesFile(
        for blocker: ContentBlockerCategory
    ) -> Bool {
        guard
            let appGroupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: GroupIdentifier.shared
                    .value
            )
        else {
            return false
        }
        let fileURL = appGroupURL.appendingPathComponent(blocker.rulesPath)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Count rules in filter content
    private static func countRules(in content: String) -> Int {
        content.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("!")
                    && !trimmed.hasPrefix("[")
            }
            .count
    }

    /// Process a single category conversion on the main actor
    @MainActor
    private static func processCategory(
        category: ContentBlockerCategory,
        content: String
    ) {
        let conversionResult =
            ContentBlockerService.convertFilterWithAdvancedRules(
                rules: content,
                groupIdentifier: GroupIdentifier.shared.value,
                rulesFilename: category.rulesPath,
                buildAdvancedEngine: false
            )
        logger.debug(
            "Converted \(conversionResult.rulesCount) rules for \(category)",
            category: logCategory
        )

        let reloadResult = ContentBlockerService.reloadContentBlocker(
            withIdentifier: ContentBlockerIdentifier.identifier(for: category)
        )
        switch reloadResult {
        case .success:
            logger.debug(
                "Reloaded content blocker for \(category)",
                category: logCategory
            )
        case .failure(let error):
            logger.error(
                "Failed to reload content blocker for \(category): \(error.localizedDescription)",
                category: logCategory
            )
        }
    }

    /// Process a single blocker conversion on the main actor
    /// Returns the actual rule count after conversion
    @MainActor
    @discardableResult
    private static func processBlocker(
        blocker: ContentBlockerCategory,
        content: String?
    ) -> Int {
        if let content = content, !content.isEmpty {
            let conversionResult =
                ContentBlockerService.convertFilterWithAdvancedRules(
                    rules: content,
                    groupIdentifier: GroupIdentifier.shared.value,
                    rulesFilename: blocker.rulesPath,
                    buildAdvancedEngine: false
                )
            logger.debug(
                "Converted \(conversionResult.rulesCount) rules for blocker\(blocker.rawValue)",
                category: logCategory
            )

            let reloadResult = ContentBlockerService.reloadContentBlocker(
                withIdentifier: ContentBlockerIdentifier.identifier(
                    for: blocker
                )
            )
            switch reloadResult {
            case .success:
                logger.debug(
                    "Reloaded content blocker for blocker\(blocker.rawValue)",
                    category: logCategory
                )
            case .failure(let error):
                logger.error(
                    "Failed to reload content blocker for blocker\(blocker.rawValue): \(error.localizedDescription)",
                    category: logCategory
                )
            }
            return conversionResult.rulesCount
        } else {
            // Clear the blocker
            let emptyBlockerJSON = """
                [{"trigger": {"url-filter": ".*","if-domain": ["example.invalid"]},"action":{"type": "ignore-previous-rules"}}]
                """
            _ = ContentBlockerService.saveContentBlocker(
                jsonRules: emptyBlockerJSON,
                groupIdentifier: GroupIdentifier.shared.value,
                rulesFilename: blocker.rulesPath
            )
            let reloadResult = ContentBlockerService.reloadContentBlocker(
                withIdentifier: ContentBlockerIdentifier.identifier(
                    for: blocker
                )
            )
            switch reloadResult {
            case .success:
                logger.debug(
                    "Cleared content blocker for blocker\(blocker.rawValue)",
                    category: logCategory
                )
            case .failure(let error):
                logger.error(
                    "Failed to reload cleared content blocker for blocker\(blocker.rawValue): \(error.localizedDescription)",
                    category: logCategory
                )
            }
            return 0
        }
    }

    /// Load enabled filters from persisted state
    static func loadEnabledFilters() async -> [FilterUpdateInfo] {
        let userDefaults =
            UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
        let manager = FilterUpdateManager.shared

        // Get enabled filter IDs
        guard
            let enabledIDs = userDefaults.stringArray(
                forKey: "enabledFilterIDs"
            )
        else {
            logger.debug(
                "No enabled filter IDs found in UserDefaults",
                category: logCategory
            )
            return []
        }

        // Load filter metadata to get URLs
        guard let metadataData = userDefaults.data(forKey: "filterListMetadata")
        else {
            logger.warning(
                "No filter metadata found in UserDefaults",
                category: logCategory
            )
            return []
        }

        let metadata: [FilterMetadataEntry]
        do {
            metadata = try JSONDecoder().decode(
                [FilterMetadataEntry].self,
                from: metadataData
            )
        } catch {
            logger.error(
                "Failed to decode filter metadata: \(error.localizedDescription)",
                category: logCategory
            )
            return []
        }

        let enabledSet = Set(enabledIDs)
        var filters: [FilterUpdateInfo] = []

        for meta in metadata where enabledSet.contains(meta.id) {
            guard let url = meta.downloadURL else {
                logger.debug(
                    "Filter \(meta.id) has no download URL, skipping",
                    category: logCategory
                )
                continue
            }

            let etag = await manager.getETag(for: meta.id)
            let lastModified = await manager.getLastModified(for: meta.id)

            filters.append(
                FilterUpdateInfo(
                    id: meta.id,
                    downloadURL: url,
                    etag: etag,
                    lastModified: lastModified,
                    sourceRuleCount: meta.sourceRuleCount
                )
            )
        }

        logger.info(
            "Loaded \(filters.count) enabled filters for update",
            category: logCategory
        )
        return filters
    }

    /// Rebuild the advanced blocking engine with all enabled filter content
    static func rebuildAdvancedEngine(filters: [FilterUpdateInfo]) async {
        var combinedAdvancedInput = ""

        for filter in filters {
            if let content = loadRawFilterContent(filterID: filter.id) {
                combinedAdvancedInput += content + "\n"
            }
        }

        if !combinedAdvancedInput.isEmpty {
            let advancedRules = ContentBlockerService.extractAdvancedRules(
                from: combinedAdvancedInput
            )
            ContentBlockerService.rebuildAdvancedBlockingEngine(
                groupIdentifier: GroupIdentifier.shared.value,
                advancedRules: advancedRules
            )
        }
    }

    /// Load raw filter content from app group
    static func loadRawFilterContent(filterID: String) -> String? {
        guard
            let appGroupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: GroupIdentifier.shared
                    .value
            )
        else {
            return nil
        }

        let directoryURL = appGroupURL.appendingPathComponent(
            AppGroupSubfolder.filterLists,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURL = directoryURL.appendingPathComponent(
            "filter-\(filterID).txt"
        )
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
}

/// Actor to safely collect filter content for load balancing
private actor FilterContentCollector {
    private var filters:
        [(filterID: String, content: String, sourceRules: Int)] = []

    func add(filterID: String, content: String, sourceRules: Int) {
        filters.append(
            (filterID: filterID, content: content, sourceRules: sourceRules)
        )
    }

    func getAll() -> [(filterID: String, content: String, sourceRules: Int)] {
        return filters
    }
}

/// Metadata entry for loading filter information
/// Note: Category field is ignored - filters are distributed purely by load balancing
private struct FilterMetadataEntry: Decodable {
    let id: String
    var downloadURL: URL?
    var sourceRuleCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case downloadURL
        case sourceRuleCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloadURL = try container.decodeIfPresent(
            URL.self,
            forKey: .downloadURL
        )
        sourceRuleCount =
            try container.decodeIfPresent(Int.self, forKey: .sourceRuleCount)
            ?? 0
    }
}

// MARK: - Cross-Platform App Delegate

#if os(iOS) || os(visionOS)

    /// iOS/visionOS App Delegate handling background tasks
    final class AppDelegate: NSObject, UIApplicationDelegate {

        private let logger = WebShieldLogger.shared
        private let logCategory = "App"
        private var launchTime: Date?
        var viewModel: FilterListViewModel?
        var hasPendingApplyNotification = false

        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication
                .LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            launchTime = Date()

            // Set up notification center delegate
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [
                .alert, .sound,
            ]) { _, _ in }

            // Log app version info
            let version =
                Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "unknown"
            let build =
                Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                ?? "unknown"

            logger.info(
                "WebShield \(version) (build \(build)) launching on iOS/visionOS",
                category: logCategory
            )

            // Ensure content blocker directory structure exists
            ContentBlockerService.ensureDirectoryStructure(
                groupIdentifier: GroupIdentifier.shared.value
            )

            // Register background tasks
            logger.debug(
                "Registering background tasks...",
                category: logCategory
            )
            FilterUpdateScheduler.shared.registerBackgroundTasks()

            // Set up the update handler
            logger.debug("Setting up update handler...", category: logCategory)
            FilterUpdateScheduler.shared.onUpdateRequested = { force, trigger in
                await FilterUpdateHandler.performFilterUpdate(
                    force: force,
                    trigger: trigger
                )
            }

            // Trigger opportunistic update on launch
            logger.debug(
                "Checking for opportunistic update...",
                category: logCategory
            )
            FilterUpdateScheduler.shared.handleAppLaunch()

            // Schedule background updates
            logger.debug(
                "Scheduling background updates...",
                category: logCategory
            )
            FilterUpdateScheduler.shared.scheduleBackgroundUpdates()

            let elapsed = Date().timeIntervalSince(launchTime ?? Date())
            let elapsedFormatted = String(format: "%.0f", elapsed * 1000)
            logger.info(
                "App launch sequence completed in \(elapsedFormatted) ms",
                category: logCategory
            )

            return true
        }

        func applicationDidBecomeActive(_ application: UIApplication) {
            logger.debug("Application did become active", category: logCategory)
            FilterUpdateScheduler.shared.handleAppBecameActive()
        }

        func applicationDidEnterBackground(_ application: UIApplication) {
            logger.debug(
                "Application entering background",
                category: logCategory
            )
            FilterUpdateScheduler.shared.handleAppEnteredBackground()
        }
    }

    extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let userInfo = response.notification.request.content.userInfo
            if let actionType = userInfo["action_type"] as? String,
                actionType == "apply_webshield_changes"
            {
                if viewModel != nil {
                    NotificationCenter.default.post(
                        name: .applyWebShieldChangesNotification,
                        object: nil
                    )
                } else {
                    hasPendingApplyNotification = true
                }
            }
            completionHandler()
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler:
                @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([])
        }
    }

#elseif os(macOS)

    /// macOS App Delegate handling background activity
    final class AppDelegate: NSObject, NSApplicationDelegate {

        private let logger = WebShieldLogger.shared
        private let logCategory = "App"
        private var launchTime: Date?
        var viewModel: FilterListViewModel?

        func applicationDidFinishLaunching(_ notification: Notification) {
            launchTime = Date()

            // Log app version info
            let version =
                Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "unknown"
            let build =
                Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                ?? "unknown"

            logger.info(
                "WebShield \(version) (build \(build)) launching on macOS",
                category: logCategory
            )

            // Ensure content blocker directory structure exists
            ContentBlockerService.ensureDirectoryStructure(
                groupIdentifier: GroupIdentifier.shared.value
            )

            // Register background tasks (macOS uses NSBackgroundActivityScheduler)
            logger.debug(
                "Registering background activity scheduler...",
                category: logCategory
            )
            FilterUpdateScheduler.shared.registerBackgroundTasks()

            // Set up the update handler
            logger.debug("Setting up update handler...", category: logCategory)
            FilterUpdateScheduler.shared.onUpdateRequested = { force, trigger in
                await FilterUpdateHandler.performFilterUpdate(
                    force: force,
                    trigger: trigger
                )
            }

            // Trigger opportunistic update on launch
            logger.debug(
                "Checking for opportunistic update...",
                category: logCategory
            )
            FilterUpdateScheduler.shared.handleAppLaunch()

            // Schedule background updates
            logger.debug(
                "Scheduling background updates...",
                category: logCategory
            )
            FilterUpdateScheduler.shared.scheduleBackgroundUpdates()

            let elapsed = Date().timeIntervalSince(launchTime ?? Date())
            let elapsedFormatted = String(format: "%.0f", elapsed * 1000)
            logger.info(
                "App launch sequence completed in \(elapsedFormatted) ms",
                category: logCategory
            )
        }

        func applicationDidBecomeActive(_ notification: Notification) {
            logger.debug("Application did become active", category: logCategory)
            FilterUpdateScheduler.shared.handleAppBecameActive()
        }

        func applicationShouldTerminate(_ sender: NSApplication)
            -> NSApplication.TerminateReply
        {
            guard let viewModel = viewModel, viewModel.hasUnappliedChanges
            else {
                return .terminateNow
            }

            let alert = NSAlert()
            alert.messageText = "Unapplied Filter Changes"
            alert.informativeText =
                "You have unapplied filter changes. Do you want to apply them before quitting?"
            alert.addButton(withTitle: "Apply Changes and Quit")
            alert.addButton(withTitle: "Quit Without Applying")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            let response = alert.runModal()

            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    await viewModel.refreshFilters()
                    DispatchQueue.main.async {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                return .terminateLater
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }

        func applicationShouldTerminateAfterLastWindowClosed(
            _ sender: NSApplication
        ) -> Bool {
            true
        }

        func applicationWillTerminate(_ notification: Notification) {
            logger.info("Application terminating", category: logCategory)
        }
    }

#endif

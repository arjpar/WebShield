//
//  FilterUpdateManager.swift
//  WebShieldService
//
//  Created by Claude on 2026-01-19.
//

import Foundation

// MARK: - Filter Update Types

/// Represents the result of checking a single filter for updates
public struct FilterUpdateCheckResult: Sendable {
    public let filterID: String
    public let hasUpdate: Bool
    public let etag: String?
    public let lastModified: String?
    public let error: String?

    public init(
        filterID: String,
        hasUpdate: Bool,
        etag: String? = nil,
        lastModified: String? = nil,
        error: String? = nil
    ) {
        self.filterID = filterID
        self.hasUpdate = hasUpdate
        self.etag = etag
        self.lastModified = lastModified
        self.error = error
    }
}

/// Represents the result of a filter download
public struct FilterDownloadResult: Sendable {
    public let filterID: String
    public let content: String?
    public let etag: String?
    public let lastModified: String?
    public let error: String?
    public let wasModified: Bool

    public init(
        filterID: String,
        content: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        error: String? = nil,
        wasModified: Bool = true
    ) {
        self.filterID = filterID
        self.content = content
        self.etag = etag
        self.lastModified = lastModified
        self.error = error
        self.wasModified = wasModified
    }
}

/// Result of an auto-update operation
public struct AutoUpdateResult: Sendable {
    public let success: Bool
    public let filtersChecked: Int
    public let filtersUpdated: Int
    public let errors: [String]
    public let duration: TimeInterval
    public let hadPartialFailure: Bool
    public let retryScheduledIn: TimeInterval?

    public init(
        success: Bool,
        filtersChecked: Int,
        filtersUpdated: Int,
        errors: [String],
        duration: TimeInterval,
        hadPartialFailure: Bool = false,
        retryScheduledIn: TimeInterval? = nil
    ) {
        self.success = success
        self.filtersChecked = filtersChecked
        self.filtersUpdated = filtersUpdated
        self.errors = errors
        self.duration = duration
        self.hadPartialFailure = hadPartialFailure
        self.retryScheduledIn = retryScheduledIn
    }
}

/// Status of the auto-update system
public struct AutoUpdateStatus: Sendable {
    public let isEnabled: Bool
    public let intervalHours: Double
    public let lastCheckTime: Date?
    public let lastSuccessfulTime: Date?
    public let nextScheduledTime: Date?
    public let isRunning: Bool
    public let isOverdue: Bool

    public init(
        isEnabled: Bool,
        intervalHours: Double,
        lastCheckTime: Date?,
        lastSuccessfulTime: Date?,
        nextScheduledTime: Date?,
        isRunning: Bool,
        isOverdue: Bool
    ) {
        self.isEnabled = isEnabled
        self.intervalHours = intervalHours
        self.lastCheckTime = lastCheckTime
        self.lastSuccessfulTime = lastSuccessfulTime
        self.nextScheduledTime = nextScheduledTime
        self.isRunning = isRunning
        self.isOverdue = isOverdue
    }
}

/// Information about a filter needed for updates
public struct FilterUpdateInfo: Sendable {
    public let id: String
    public let downloadURL: URL
    public let etag: String?
    public let lastModified: String?
    /// Estimated number of rules in the filter (for load balancing)
    public let sourceRuleCount: Int

    public init(
        id: String,
        downloadURL: URL,
        etag: String? = nil,
        lastModified: String? = nil,
        sourceRuleCount: Int = 0
    ) {
        self.id = id
        self.downloadURL = downloadURL
        self.etag = etag
        self.lastModified = lastModified
        self.sourceRuleCount = sourceRuleCount
    }
}

// MARK: - Filter Update Manager

/// Thread-safe actor managing filter list updates across all platforms
/// Combines best practices from wBlock, AdGuard Safari, and AdGuard iOS
public actor FilterUpdateManager {

    // MARK: - Singleton

    public static let shared = FilterUpdateManager()

    // MARK: - Constants

    private enum Keys {
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let autoUpdateIntervalHours = "autoUpdateIntervalHours"
        static let lastCheckTime = "autoUpdateLastCheckTime"
        static let lastSuccessfulTime = "autoUpdateLastSuccessfulTime"
        static let nextScheduledTime = "autoUpdateNextScheduledTime"
        static let isRunning = "autoUpdateIsRunning"
        static let runningSinceTimestamp = "autoUpdateRunningSinceTimestamp"
        static let isPipelineActive = "autoUpdateIsPipelineActive"
        static let pipelineSinceTimestamp = "autoUpdatePipelineSinceTimestamp"
        static let filterETags = "filterETags"
        static let filterLastModified = "filterLastModified"
        static let lastAppliedFiltersByCategory = "lastAppliedFiltersByCategory"
    }

    private enum Defaults {
        static let intervalHours: Double = 6.0
        static let minIntervalHours: Double = 1.0
        static let maxIntervalHours: Double = 24.0
        static let staleRunningThresholdSeconds: TimeInterval = 180  // 3 minutes
        static let stalePipelineThresholdSeconds: TimeInterval = 1800  // 30 minutes
        static let requestTimeoutSeconds: TimeInterval = 30
        static let resourceTimeoutSeconds: TimeInterval = 120
        // Heartbeat: Refresh running timestamp during long updates
        static let heartbeatIntervalSeconds: TimeInterval = 60
        // Debounced saves: Batch rapid state changes
        static let saveDebounceMilliseconds: UInt64 = 500
        // Minimum rules: Reject empty/broken filter downloads
        static let minimumRuleCount: Int = 3
        // Partial failure retry: Retry sooner when some filters fail
        static let partialFailureRetryFraction: Double = 0.25
        static let partialFailureMinRetrySeconds: TimeInterval = 900  // 15 minutes
        static let partialFailureMaxRetrySeconds: TimeInterval = 3600  // 1 hour
    }

    // MARK: - Properties

    private let logger = WebShieldLogger.shared
    private let logCategory = "Updates"
    private var isRunning = false
    private var lastStatusCacheTime: Date?
    private var cachedStatus: AutoUpdateStatus?
    private var pendingSaveTask: Task<Void, Never>?

    private var userDefaults: UserDefaults {
        UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
    }

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Defaults.requestTimeoutSeconds
        config.timeoutIntervalForResource = Defaults.resourceTimeoutSeconds
        config.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 0
        )
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Debounced Save Infrastructure

    /// Schedule a debounced save (500ms delay, coalesces rapid changes)
    /// Note: UserDefaults auto-synchronizes, but debouncing helps batch rapid changes
    private func saveDefaultsDebounced() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            do {
                try await Task.sleep(
                    nanoseconds: Defaults.saveDebounceMilliseconds * 1_000_000
                )
            } catch {
                return  // Cancelled
            }
            // UserDefaults automatically persists changes; no need to call synchronize()
        }
    }

    /// Save immediately (for critical state changes like running flag)
    /// Note: UserDefaults auto-synchronizes; this just cancels any pending debounced save
    private func saveDefaultsImmediately() {
        pendingSaveTask?.cancel()
        // UserDefaults automatically persists changes; no need to call synchronize()
    }

    // MARK: - Raw Filter Cache

    private static var appGroupURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GroupIdentifier.shared.value
        )
    }

    private func subdirectoryURL(named subfolder: String) -> URL? {
        guard let appGroupURL = Self.appGroupURL else { return nil }
        let directoryURL = appGroupURL.appendingPathComponent(
            subfolder,
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
                "Failed to create app group directory \(subfolder): \(error.localizedDescription)",
                category: logCategory
            )
            return nil
        }
    }

    private func rawFilterFileURL(filterID: String) -> URL? {
        subdirectoryURL(named: AppGroupSubfolder.filterLists)?
            .appendingPathComponent("filter-\(filterID).txt")
    }

    private func loadRawFilterContent(filterID: String) -> String? {
        guard let fileURL = rawFilterFileURL(filterID: filterID) else {
            return nil
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    public func saveRawFilterContent(_ content: String, filterID: String) {
        guard let fileURL = rawFilterFileURL(filterID: filterID) else {
            logger.error(
                "[\(filterID)] Failed to resolve app group URL",
                category: logCategory
            )
            return
        }

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            let fileSize = formatBytes(content.utf8.count)
            logger.debug(
                "[\(filterID)] Saved raw filter content (\(fileSize))",
                category: logCategory
            )
        } catch {
            logger.error(
                "[\(filterID)] Failed to save filter content: \(error.localizedDescription)",
                category: logCategory
            )
        }
    }

    /// Retrieves cached raw filter content from the app group container
    /// - Parameter filterID: The unique identifier for the filter
    /// - Returns: The cached filter content, or nil if not found
    public func getRawFilterContent(filterID: String) -> String? {
        return loadRawFilterContent(filterID: filterID)
    }

    // MARK: - Last Applied Filter State

    /// Get the set of filter IDs that were last applied to a category's content blocker
    /// - Parameter category: The content blocker category
    /// - Returns: Set of filter IDs that were included in the last content blocker build
    public func getLastAppliedFilters(for category: ContentBlockerCategory) -> Set<String> {
        guard let stored = userDefaults.dictionary(forKey: Keys.lastAppliedFiltersByCategory)
            as? [String: [String]],
            let filterIDs = stored[String(category.rawValue)]
        else {
            return []
        }
        return Set(filterIDs)
    }

    /// Set the filter IDs that are currently applied to a category's content blocker
    /// - Parameters:
    ///   - filterIDs: Set of filter IDs included in the content blocker
    ///   - category: The content blocker category
    public func setLastAppliedFilters(_ filterIDs: Set<String>, for category: ContentBlockerCategory) {
        var stored =
            userDefaults.dictionary(forKey: Keys.lastAppliedFiltersByCategory) as? [String: [String]]
            ?? [:]
        stored[String(category.rawValue)] = Array(filterIDs)
        userDefaults.set(stored, forKey: Keys.lastAppliedFiltersByCategory)
    }

    // MARK: - Initialization

    private init() {
        // Clear any stale running flags on initialization
        // Note: This runs asynchronously, but shouldRunUpdate() also calls clearStaleRunningFlag()
        // before checking the running state, so there's no race condition in practice
        Task {
            await clearStaleRunningFlag()
            await clearStalePipelineFlag()
        }
    }

    // MARK: - Public Settings API

    /// Whether automatic filter updates are enabled
    public var isAutoUpdateEnabled: Bool {
        get { userDefaults.bool(forKey: Keys.autoUpdateEnabled) }
        set {
            userDefaults.set(newValue, forKey: Keys.autoUpdateEnabled)
            cachedStatus = nil
        }
    }

    /// Update interval in hours (default 6 hours)
    public var updateIntervalHours: Double {
        get {
            let stored = userDefaults.double(
                forKey: Keys.autoUpdateIntervalHours
            )
            return stored > 0 ? stored : Defaults.intervalHours
        }
        set {
            let clamped = min(
                max(newValue, Defaults.minIntervalHours),
                Defaults.maxIntervalHours
            )
            userDefaults.set(clamped, forKey: Keys.autoUpdateIntervalHours)
            cachedStatus = nil
        }
    }

    /// Set auto-update enabled state
    public func setAutoUpdateEnabled(_ enabled: Bool) {
        isAutoUpdateEnabled = enabled

        if enabled {
            let now = Date()
            let referenceTime = lastCheckTime ?? now
            let computedNextTime = referenceTime.addingTimeInterval(
                updateIntervalHours * 3600
            )
            nextScheduledTime = computedNextTime
            logger.info(
                "Auto-update enabled, next scheduled: \(computedNextTime)",
                category: logCategory
            )
        } else {
            nextScheduledTime = nil
            logger.info(
                "Auto-update disabled, cleared next scheduled time",
                category: logCategory
            )
        }

        cachedStatus = nil
        saveDefaultsImmediately()
    }

    /// Set update interval in hours
    /// Recalculates nextScheduledTime so schedule changes are reflected immediately.
    public func setUpdateIntervalHours(_ hours: Double) {
        let oldInterval = updateIntervalHours
        updateIntervalHours = hours

        // Recalculate schedule from last check when available, otherwise from now
        // if auto-update is enabled and no run has happened yet.
        if let lastCheck = lastCheckTime {
            let newNextTime = lastCheck.addingTimeInterval(hours * 3600)
            nextScheduledTime = newNextTime
            logger.info(
                "Interval changed from \(oldInterval)h to \(hours)h, next scheduled: \(newNextTime)",
                category: logCategory
            )
        } else if isAutoUpdateEnabled {
            let newNextTime = Date().addingTimeInterval(hours * 3600)
            nextScheduledTime = newNextTime
            logger.info(
                "Interval changed from \(oldInterval)h to \(hours)h with no prior check, next scheduled: \(newNextTime)",
                category: logCategory
            )
        }
    }

    /// Set the last successful update time to now
    public func setLastSuccessfulTimeNow() {
        lastSuccessfulTime = Date()
    }

    /// Last time an update check was attempted
    public var lastCheckTime: Date? {
        get {
            let timestamp = userDefaults.double(forKey: Keys.lastCheckTime)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let date = newValue {
                userDefaults.set(
                    date.timeIntervalSince1970,
                    forKey: Keys.lastCheckTime
                )
            } else {
                userDefaults.removeObject(forKey: Keys.lastCheckTime)
            }
        }
    }

    /// Last time filters were successfully updated
    public var lastSuccessfulTime: Date? {
        get {
            let timestamp = userDefaults.double(forKey: Keys.lastSuccessfulTime)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let date = newValue {
                userDefaults.set(
                    date.timeIntervalSince1970,
                    forKey: Keys.lastSuccessfulTime
                )
            } else {
                userDefaults.removeObject(forKey: Keys.lastSuccessfulTime)
            }
        }
    }

    /// Next scheduled update time
    public var nextScheduledTime: Date? {
        get {
            let timestamp = userDefaults.double(forKey: Keys.nextScheduledTime)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let date = newValue {
                userDefaults.set(
                    date.timeIntervalSince1970,
                    forKey: Keys.nextScheduledTime
                )
            } else {
                userDefaults.removeObject(forKey: Keys.nextScheduledTime)
            }
        }
    }

    // MARK: - Status

    /// Get current auto-update status
    public func getStatus() -> AutoUpdateStatus {
        // Use cached status if recent (5 seconds)
        if let cached = cachedStatus,
            let cacheTime = lastStatusCacheTime,
            Date().timeIntervalSince(cacheTime) < 5
        {
            return cached
        }

        // Clear stale running flags before checking status
        // This ensures accurate isRunning state even if init() task hasn't completed
        clearStaleRunningFlag()
        clearStalePipelineFlag()

        let now = Date()
        let nextTime =
            nextScheduledTime
            ?? lastCheckTime.map {
                $0.addingTimeInterval(updateIntervalHours * 3600)
            }

        let isOverdue: Bool
        if let next = nextTime {
            isOverdue = now > next.addingTimeInterval(3600)  // 1 hour grace
        } else {
            isOverdue = false
        }

        let status = AutoUpdateStatus(
            isEnabled: isAutoUpdateEnabled,
            intervalHours: updateIntervalHours,
            lastCheckTime: lastCheckTime,
            lastSuccessfulTime: lastSuccessfulTime,
            nextScheduledTime: nextTime,
            isRunning: isRunning || isUpdatePipelineActive(),
            isOverdue: isOverdue
        )

        cachedStatus = status
        lastStatusCacheTime = now

        return status
    }

    /// Sets whether end-to-end auto-update work is currently active.
    /// This is used by UI to keep the indicator visible through download,
    /// conversion, save-to-disk, and content blocker reload phases.
    public func setUpdatePipelineActive(_ active: Bool) {
        userDefaults.set(active, forKey: Keys.isPipelineActive)
        if active {
            userDefaults.set(
                Date().timeIntervalSince1970,
                forKey: Keys.pipelineSinceTimestamp
            )
        } else {
            userDefaults.removeObject(forKey: Keys.pipelineSinceTimestamp)
        }
        cachedStatus = nil
        saveDefaultsImmediately()
    }

    // MARK: - ETag/Last-Modified Storage

    /// Get stored ETag for a filter
    public func getETag(for filterID: String) -> String? {
        let etags =
            userDefaults.dictionary(forKey: Keys.filterETags)
            as? [String: String]
        return etags?[filterID]
    }

    /// Set ETag for a filter
    public func setETag(_ etag: String?, for filterID: String) {
        var etags =
            userDefaults.dictionary(forKey: Keys.filterETags)
            as? [String: String] ?? [:]
        etags[filterID] = etag
        userDefaults.set(etags, forKey: Keys.filterETags)
    }

    /// Get stored Last-Modified for a filter
    public func getLastModified(for filterID: String) -> String? {
        let lastModified =
            userDefaults.dictionary(forKey: Keys.filterLastModified)
            as? [String: String]
        return lastModified?[filterID]
    }

    /// Set Last-Modified for a filter
    public func setLastModified(_ lastModified: String?, for filterID: String) {
        var stored =
            userDefaults.dictionary(forKey: Keys.filterLastModified)
            as? [String: String] ?? [:]
        stored[filterID] = lastModified
        userDefaults.set(stored, forKey: Keys.filterLastModified)
    }

    // MARK: - Running State Management

    private func setRunningState(_ running: Bool) {
        isRunning = running
        userDefaults.set(running, forKey: Keys.isRunning)
        if running {
            userDefaults.set(
                Date().timeIntervalSince1970,
                forKey: Keys.runningSinceTimestamp
            )
        } else {
            userDefaults.removeObject(forKey: Keys.runningSinceTimestamp)
        }
        // Invalidate status cache
        cachedStatus = nil
        // Critical state change - save immediately
        saveDefaultsImmediately()
    }

    /// Refresh the heartbeat timestamp during long-running updates
    private func refreshHeartbeat() {
        userDefaults.set(
            Date().timeIntervalSince1970,
            forKey: Keys.runningSinceTimestamp
        )
        saveDefaultsImmediately()
    }

    private func clearStaleRunningFlag() {
        let storedRunning = userDefaults.bool(forKey: Keys.isRunning)
        guard storedRunning else { return }

        let timestamp = userDefaults.double(forKey: Keys.runningSinceTimestamp)
        guard timestamp > 0 else {
            // No timestamp but running flag set - clear it
            userDefaults.set(false, forKey: Keys.isRunning)
            return
        }

        let runningSince = Date(timeIntervalSince1970: timestamp)
        let elapsed = Date().timeIntervalSince(runningSince)

        if elapsed > Defaults.staleRunningThresholdSeconds {
            let elapsedSeconds = String(format: "%.1f", elapsed)
            logger.warning(
                "Clearing stale running flag (elapsed: \(elapsedSeconds)s)",
                category: logCategory
            )
            userDefaults.set(false, forKey: Keys.isRunning)
            userDefaults.removeObject(forKey: Keys.runningSinceTimestamp)
        }
    }

    private func isUpdatePipelineActive() -> Bool {
        userDefaults.bool(forKey: Keys.isPipelineActive)
    }

    private func clearStalePipelineFlag() {
        let isPipelineActive = userDefaults.bool(forKey: Keys.isPipelineActive)
        guard isPipelineActive else { return }

        let timestamp = userDefaults.double(forKey: Keys.pipelineSinceTimestamp)
        guard timestamp > 0 else {
            userDefaults.set(false, forKey: Keys.isPipelineActive)
            return
        }

        let pipelineSince = Date(timeIntervalSince1970: timestamp)
        let elapsed = Date().timeIntervalSince(pipelineSince)

        if elapsed > Defaults.stalePipelineThresholdSeconds {
            let elapsedSeconds = String(format: "%.1f", elapsed)
            logger.warning(
                "Clearing stale pipeline flag (elapsed: \(elapsedSeconds)s)",
                category: logCategory
            )
            userDefaults.set(false, forKey: Keys.isPipelineActive)
            userDefaults.removeObject(forKey: Keys.pipelineSinceTimestamp)
        }
    }

    // MARK: - Debug Helpers

    #if DEBUG
        /// Sets the running state for debugging/testing purposes
        /// This allows testing the auto-update indicator UI without triggering a real update
        public func setDebugRunningState(_ running: Bool) {
            logger.debug(
                "Debug: Setting running state to \(running)",
                category: logCategory
            )
            setRunningState(running)
        }
    #endif

    // MARK: - Update Check Logic

    /// Check if enough time has passed since last update
    public func shouldRunUpdate(force: Bool = false) -> Bool {
        guard isAutoUpdateEnabled || force else {
            logger.debug(
                "Auto-update disabled and not forced",
                category: logCategory
            )
            return false
        }

        // Clear stale running flags
        clearStaleRunningFlag()

        // Don't start if already running
        guard !isRunning else {
            logger.debug("Update already in progress", category: logCategory)
            return false
        }

        // Force always runs
        if force {
            return true
        }

        // Check time-based eligibility
        let now = Date()

        // First, check nextScheduledTime if available
        if let nextTime = nextScheduledTime {
            if now >= nextTime {
                return true
            }
            logger.debug(
                "Not yet eligible, next scheduled: \(nextTime)",
                category: logCategory
            )
            return false
        }

        // Fallback to lastCheckTime + interval
        if let lastCheck = lastCheckTime {
            let eligibleTime = lastCheck.addingTimeInterval(
                updateIntervalHours * 3600
            )
            if now >= eligibleTime {
                return true
            }
            logger.debug(
                "Not yet eligible based on last check time",
                category: logCategory
            )
            return false
        }

        // No previous check - run immediately
        return true
    }

    // MARK: - Network Operations

    /// Check if a filter has updates using conditional requests
    public func checkForUpdate(
        filterID: String,
        url: URL,
        currentETag: String?,
        currentLastModified: String?
    ) async -> FilterUpdateCheckResult {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        // Add conditional headers
        if let etag = currentETag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = currentLastModified {
            request.setValue(
                lastModified,
                forHTTPHeaderField: "If-Modified-Since"
            )
        }

        // Add browser-like headers for better compatibility
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (_, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return FilterUpdateCheckResult(
                    filterID: filterID,
                    hasUpdate: true,  // Assume update needed if we can't parse response
                    error: "Invalid response type"
                )
            }

            // 304 Not Modified = no update needed
            if httpResponse.statusCode == 304 {
                return FilterUpdateCheckResult(
                    filterID: filterID,
                    hasUpdate: false,
                    etag: currentETag,
                    lastModified: currentLastModified
                )
            }

            // Success status = content available, check headers
            if (200...299).contains(httpResponse.statusCode) {
                let newETag = httpResponse.value(forHTTPHeaderField: "ETag")
                let newLastModified = httpResponse.value(
                    forHTTPHeaderField: "Last-Modified"
                )

                // Compare ETags if available
                if let oldETag = currentETag, let newETag = newETag {
                    let hasUpdate = oldETag != newETag
                    return FilterUpdateCheckResult(
                        filterID: filterID,
                        hasUpdate: hasUpdate,
                        etag: newETag,
                        lastModified: newLastModified
                    )
                }

                // If no ETag comparison possible, assume update available
                return FilterUpdateCheckResult(
                    filterID: filterID,
                    hasUpdate: true,
                    etag: newETag,
                    lastModified: newLastModified
                )
            }

            return FilterUpdateCheckResult(
                filterID: filterID,
                hasUpdate: false,
                error: "HTTP \(httpResponse.statusCode)"
            )

        } catch {
            return FilterUpdateCheckResult(
                filterID: filterID,
                hasUpdate: true,  // Assume update on network error to retry later
                error: error.localizedDescription
            )
        }
    }

    /// Download a filter with conditional request support
    public func downloadFilter(
        filterID: String,
        url: URL,
        currentETag: String?,
        currentLastModified: String?
    ) async -> FilterDownloadResult {
        let startTime = DispatchTime.now()

        logger.debug(
            "[\(filterID)] Starting download from \(url.host ?? url.absoluteString)",
            category: logCategory
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Add conditional headers
        if let etag = currentETag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            logger.debug(
                "[\(filterID)] Using cached ETag: \(etag.prefix(20))...",
                category: logCategory
            )
        }
        if let lastModified = currentLastModified {
            request.setValue(
                lastModified,
                forHTTPHeaderField: "If-Modified-Since"
            )
        }

        // Add browser-like headers
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await urlSession.data(for: request)

            let endTime = DispatchTime.now()
            let elapsedMs =
                Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds)
                / 1_000_000
            let elapsedFormatted = String(format: "%.0f", elapsedMs)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error(
                    "[\(filterID)] Invalid response type after \(elapsedFormatted) ms",
                    category: logCategory
                )
                return FilterDownloadResult(
                    filterID: filterID,
                    error: "Invalid response type"
                )
            }

            // 304 Not Modified
            if httpResponse.statusCode == 304 {
                logger.debug(
                    "[\(filterID)] Not modified (304) in \(elapsedFormatted) ms",
                    category: logCategory
                )
                return FilterDownloadResult(
                    filterID: filterID,
                    etag: currentETag,
                    lastModified: currentLastModified,
                    wasModified: false
                )
            }

            // Success
            if (200...299).contains(httpResponse.statusCode) {
                guard let content = String(data: data, encoding: .utf8) else {
                    logger.error(
                        "[\(filterID)] Failed to decode \(formatBytes(data.count)) as UTF-8",
                        category: logCategory
                    )
                    return FilterDownloadResult(
                        filterID: filterID,
                        error: "Failed to decode content as UTF-8"
                    )
                }

                // Validate content isn't HTML (DDoS protection page)
                let contentType =
                    httpResponse.value(forHTTPHeaderField: "Content-Type")?
                    .lowercased() ?? ""
                if isHTMLResponse(contentType: contentType, content: content) {
                    logger.warning(
                        "[\(filterID)] Received HTML instead of filter content (Content-Type: \(contentType))",
                        category: logCategory
                    )
                    return FilterDownloadResult(
                        filterID: filterID,
                        error:
                            "Received HTML instead of filter content (possible DDoS protection)"
                    )
                }

                // Validate minimum rule count (reject empty/broken downloads)
                let ruleCount = countRulesInContent(content)
                if ruleCount < Defaults.minimumRuleCount {
                    logger.warning(
                        "[\(filterID)] Only \(ruleCount) rules (minimum: \(Defaults.minimumRuleCount))",
                        category: logCategory
                    )
                    return FilterDownloadResult(
                        filterID: filterID,
                        error:
                            "Insufficient rules (\(ruleCount) < \(Defaults.minimumRuleCount))"
                    )
                }

                let newETag = httpResponse.value(forHTTPHeaderField: "ETag")
                let newLastModified = httpResponse.value(
                    forHTTPHeaderField: "Last-Modified"
                )
                let lineCount = content.components(separatedBy: "\n").count

                logger.info(
                    "[\(filterID)] Downloaded \(formatBytes(data.count)) (\(lineCount) lines) in \(elapsedFormatted) ms",
                    category: logCategory
                )

                return FilterDownloadResult(
                    filterID: filterID,
                    content: content,
                    etag: newETag,
                    lastModified: newLastModified,
                    wasModified: true
                )
            }

            logger.warning(
                "[\(filterID)] HTTP \(httpResponse.statusCode) after \(elapsedFormatted) ms",
                category: logCategory
            )
            return FilterDownloadResult(
                filterID: filterID,
                error: "HTTP \(httpResponse.statusCode)"
            )

        } catch let error as URLError {
            let errorCode = error.code.rawValue
            logger.error(
                "[\(filterID)] Network error: \(error.localizedDescription) (URLError \(errorCode))",
                category: logCategory
            )
            return FilterDownloadResult(
                filterID: filterID,
                error: "Network error: \(error.localizedDescription)"
            )
        } catch {
            logger.error(
                "[\(filterID)] Download failed: \(error.localizedDescription)",
                category: logCategory
            )
            return FilterDownloadResult(
                filterID: filterID,
                error: error.localizedDescription
            )
        }
    }

    /// Validate that response is not HTML (DDoS protection page, error page, etc.)
    /// Uses Content-Type header as primary signal, with content inspection as fallback
    private func isHTMLResponse(contentType: String, content: String) -> Bool {
        // Primary check: Content-Type header (most reliable)
        if contentType.contains("text/html")
            || contentType.contains("application/xhtml")
        {
            return true
        }

        // Secondary check: content inspection for cases where Content-Type is missing/wrong
        // Only inspect the beginning to avoid false positives from filter rules
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Check if content starts with HTML markers
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
            return true
        }

        // Check first 512 chars for structural HTML tags
        // Real HTML has these near the top; filter lists won't
        let prefix = String(trimmed.prefix(512))
        return prefix.contains("<head") || prefix.contains("<body")
    }

    /// Count actual filter rules in content (excluding comments and metadata)
    /// Note: Lines starting with # are valid CSS selector rules (e.g., ##.ad-banner), not comments
    private func countRulesInContent(_ content: String) -> Int {
        var count = 0
        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty lines, comments (!), and standalone metadata headers ([...])
            // Keep rule lines that start with bracketed modifiers (for example: [$path=...])
            // Note: # prefix is for CSS selector rules (##, #@#, #$#, etc.) - these ARE valid rules
            if !trimmed.isEmpty
                && !trimmed.hasPrefix("!")
                && !Self.isStandaloneSectionHeader(trimmed)
            {
                count += 1
            }
        }
        return count
    }

    /// Returns true for metadata headers like `[Adblock Plus 2.0]`.
    /// Rule lines with bracketed modifiers (for example `[$path=...]example.com##...`) return false.
    private static func isStandaloneSectionHeader(_ line: String) -> Bool {
        guard line.hasPrefix("["),
            let closingBracket = line.firstIndex(of: "]")
        else {
            return false
        }

        return line.index(after: closingBracket) == line.endIndex
    }

    // MARK: - Batch Update Operations

    /// Check multiple filters for updates in parallel with cancellation support
    public func checkFiltersForUpdates(
        filters: [FilterUpdateInfo]
    ) async -> [FilterUpdateCheckResult] {
        await withTaskGroup(of: FilterUpdateCheckResult.self) { group in
            for filter in filters {
                // Check for cancellation before starting each check
                if Task.isCancelled {
                    break
                }

                group.addTask {
                    // Check for cancellation at start of each task
                    if Task.isCancelled {
                        return FilterUpdateCheckResult(
                            filterID: filter.id,
                            hasUpdate: false,
                            error: "Cancelled"
                        )
                    }

                    return await self.checkForUpdate(
                        filterID: filter.id,
                        url: filter.downloadURL,
                        currentETag: filter.etag,
                        currentLastModified: filter.lastModified
                    )
                }
            }

            var results: [FilterUpdateCheckResult] = []
            for await result in group {
                // Check for cancellation while collecting results
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                results.append(result)
            }
            return results
        }
    }

    /// Download multiple filters in parallel with cancellation support
    public func downloadFilters(
        filters: [FilterUpdateInfo]
    ) async -> [FilterDownloadResult] {
        await withTaskGroup(of: FilterDownloadResult.self) { group in
            for filter in filters {
                // Check for cancellation before starting each download
                if Task.isCancelled {
                    logger.info(
                        "Download cancelled before starting \(filter.id)",
                        category: logCategory
                    )
                    break
                }

                group.addTask {
                    // Check for cancellation at start of each task
                    if Task.isCancelled {
                        return FilterDownloadResult(
                            filterID: filter.id,
                            error: "Cancelled"
                        )
                    }

                    return await self.downloadFilter(
                        filterID: filter.id,
                        url: filter.downloadURL,
                        currentETag: filter.etag,
                        currentLastModified: filter.lastModified
                    )
                }
            }

            var results: [FilterDownloadResult] = []
            for await result in group {
                // Check for cancellation while collecting results
                if Task.isCancelled {
                    logger.info(
                        "Download collection cancelled, returning partial results",
                        category: logCategory
                    )
                    group.cancelAll()
                    break
                }
                results.append(result)
            }
            return results
        }
    }

    // MARK: - Main Update Entry Point

    /// Attempt to run an auto-update if conditions are met
    /// - Parameters:
    ///   - filters: List of enabled filters to update
    ///   - force: Force update regardless of timing
    ///   - onFilterUpdated: Callback when a filter is downloaded (for UI progress)
    /// - Returns: Result of the update operation
    public func maybeRunAutoUpdate(
        filters: [FilterUpdateInfo],
        force: Bool = false,
        onFilterUpdated: ((String) -> Void)? = nil
    ) async -> AutoUpdateResult? {
        guard shouldRunUpdate(force: force) else {
            return nil
        }

        return await runUpdate(
            filters: filters,
            onFilterUpdated: onFilterUpdated
        )
    }

    /// Execute the update operation
    private func runUpdate(
        filters: [FilterUpdateInfo],
        onFilterUpdated: ((String) -> Void)?
    ) async -> AutoUpdateResult {
        let startTime = Date()
        setRunningState(true)

        // Start heartbeat task to prevent false stale detection during long updates
        let heartbeatTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Defaults.heartbeatIntervalSeconds)
                            * 1_000_000_000
                    )
                } catch {
                    break  // Cancelled
                }
                if Task.isCancelled { break }
                await self?.refreshHeartbeat()
            }
        }

        // Track for partial failure retry calculation
        var errors: [String] = []
        var filtersUpdated = 0

        defer {
            heartbeatTask.cancel()
            setRunningState(false)
            lastCheckTime = Date()
        }

        logger.info(
            "Starting filter update for \(filters.count) filters",
            category: logCategory
        )

        // Download all filters that need updates
        let downloadResults = await downloadFilters(filters: filters)

        for result in downloadResults {
            if let error = result.error {
                errors.append("\(result.filterID): \(error)")
                logger.error(
                    "Download error for \(result.filterID): \(error)",
                    category: logCategory
                )
                continue
            }

            if result.wasModified, let content = result.content {
                filtersUpdated += 1

                // Update stored ETag/Last-Modified
                setETag(result.etag, for: result.filterID)
                setLastModified(result.lastModified, for: result.filterID)
                saveRawFilterContent(content, filterID: result.filterID)

                onFilterUpdated?(result.filterID)
                logger.debug(
                    "Downloaded update for \(result.filterID)",
                    category: logCategory
                )
            }
        }

        // Use single timestamp for consistency
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)

        if filtersUpdated > 0 {
            lastSuccessfulTime = endTime
        }

        let durationSeconds = String(format: "%.2f", duration)
        logger.info(
            "Filter update completed: \(filtersUpdated)/\(filters.count) updated in \(durationSeconds)s",
            category: logCategory
        )

        // Calculate failure state and schedule next update
        // Note: This must happen before return so retryScheduledIn has the correct value
        let hasAnyFailure = !errors.isEmpty
        let hadPartialFailure = hasAnyFailure && errors.count < filters.count
        var retryScheduledIn: TimeInterval? = nil

        if hasAnyFailure {
            // Any failure (partial or total): retry sooner
            // This fixes the bug where total failure didn't trigger shorter retry interval
            let retrySeconds = min(
                Defaults.partialFailureMaxRetrySeconds,
                max(
                    Defaults.partialFailureMinRetrySeconds,
                    updateIntervalHours * 3600
                        * Defaults.partialFailureRetryFraction
                )
            )
            let jitter = Double.random(in: -60...60)
            retryScheduledIn = retrySeconds + jitter
            nextScheduledTime = endTime.addingTimeInterval(
                retrySeconds + jitter
            )
            let failureType = hadPartialFailure ? "Partial" : "Total"
            logger.info(
                "\(failureType) failure (\(errors.count)/\(filters.count)) - retry in \(Int(retrySeconds))s",
                category: logCategory
            )
        } else {
            // Success: normal scheduling with jitter
            let jitter = Double.random(in: -300...300)  // ±5 minutes
            nextScheduledTime = endTime.addingTimeInterval(
                updateIntervalHours * 3600 + jitter
            )
        }

        return AutoUpdateResult(
            success: errors.isEmpty,
            filtersChecked: filters.count,
            filtersUpdated: filtersUpdated,
            errors: errors,
            duration: duration,
            hadPartialFailure: hadPartialFailure,
            retryScheduledIn: retryScheduledIn
        )
    }

    // MARK: - Logging

    /// Append a message to the shared update log
    public func appendToLog(_ message: String) {
        logger.info(message, category: logCategory)
    }

    /// Read the update log as formatted text
    public func readLog() async -> String? {
        let entries = await WebShieldLogFileStore.shared.readEntries(
            categories: Set([logCategory])
        )

        guard !entries.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        return entries.map { entry in
            "[\(formatter.string(from: entry.date))] [\(entry.level.displayName.uppercased())] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }

    /// Clear the update log entries
    public func clearLog() async {
        await WebShieldLogFileStore.shared.clear(categories: Set([logCategory]))
    }

    // MARK: - Shared Auto-Update Log File

    /// URL for the shared auto-update log file (cross-process visible)
    private var sharedLogFileURL: URL? {
        subdirectoryURL(named: AppGroupSubfolder.logs)?
            .appendingPathComponent("autoupdate.log")
    }

    /// Append a message to the shared auto-update log file
    /// This log is append-only and visible across all processes (app + extensions)
    public func appendSharedLog(_ message: String) {
        guard let url = sharedLogFileURL else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }

        // Also log to main logger for UI visibility
        logger.info(message, category: logCategory)
    }

    /// Read the shared auto-update log file contents
    public func readSharedLog() -> String? {
        guard let url = sharedLogFileURL,
            FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Clear the shared auto-update log file
    public func clearSharedLog() {
        guard let url = sharedLogFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Get the size of the shared log file in bytes
    public func sharedLogSize() -> Int? {
        guard let url = sharedLogFileURL,
            let attrs = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let size = attrs[.size] as? Int
        else {
            return nil
        }
        return size
    }
}

//
//  FilterUpdateScheduler.swift
//  WebShieldService
//
//  Created by Claude on 2026-01-19.
//

import Foundation

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

// MARK: - Task Cancellation State

/// Thread-safe actor for tracking task cancellation state
/// Replaces unsafe pointer approach to avoid data races
private actor TaskCancellationState {
    private var cancelled = false

    func setCancelled() {
        cancelled = true
    }

    func isCancelled() -> Bool {
        return cancelled
    }
}

/// Wrapper for reference types that are known to be safe to pass across tasks.
private final class UncheckedSendableBox<Value: AnyObject>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - Filter Update Scheduler

/// Cross-platform scheduler for automatic filter updates
/// - iOS/iPadOS/visionOS: Uses BGAppRefreshTask and BGProcessingTask
/// - macOS: Uses NSBackgroundActivityScheduler
public final class FilterUpdateScheduler: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = FilterUpdateScheduler()

    // MARK: - Constants

    public enum TaskIdentifier {
        public static let appRefresh = "arjun.webshield.filter-refresh"
        public static let processing = "arjun.webshield.filter-processing"

        #if os(macOS)
            public static let macOSActivity =
                "arjun.webshield.filter-update"
        #endif
    }

    private enum Defaults {
        static let minDelaySeconds: TimeInterval = 60 * 15  // 15 minutes minimum
        static let maxDelaySeconds: TimeInterval = 60 * 60 * 24  // 24 hours maximum
        static let periodicTimerInterval: TimeInterval = 60 * 30  // 30 minutes
    }

    // MARK: - Properties

    private let logger = WebShieldLogger.shared
    private let logCategory = "Updates"

    /// Lock protecting mutable state
    private let lock = NSLock()

    #if os(macOS)
        /// Must be accessed on main thread only
        @MainActor private var backgroundActivity:
            NSBackgroundActivityScheduler?
        @MainActor private var periodicTimer: Timer?
    #endif

    /// Internal storage for update callback, protected by lock
    private var _onUpdateRequested:
        (@Sendable (_ force: Bool, _ trigger: String) async -> Void)?

    /// Callback invoked when a background update should run
    /// The implementation should perform the actual filter update
    public var onUpdateRequested:
        (@Sendable (_ force: Bool, _ trigger: String) async -> Void)?
    {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onUpdateRequested
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onUpdateRequested = newValue
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Registration

    /// Register background task handlers
    /// Must be called early in app lifecycle (e.g., application:didFinishLaunching)
    public func registerBackgroundTasks() {
        #if os(iOS) || os(visionOS)
            registerIOSBackgroundTasks()
        #elseif os(macOS)
            // macOS doesn't require pre-registration
            logger.info("macOS scheduler ready", category: logCategory)
        #endif
    }

    #if os(iOS) || os(visionOS)
        private func registerIOSBackgroundTasks() {
            logger.debug(
                "Registering background task: \(TaskIdentifier.appRefresh)",
                category: logCategory
            )

            // Register app refresh task
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: TaskIdentifier.appRefresh,
                using: nil
            ) { [weak self] task in
                guard let task = task as? BGAppRefreshTask else { return }
                self?.handleAppRefreshTask(task)
            }

            logger.debug(
                "Registering background task: \(TaskIdentifier.processing)",
                category: logCategory
            )

            // Register processing task
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: TaskIdentifier.processing,
                using: nil
            ) { [weak self] task in
                guard let task = task as? BGProcessingTask else { return }
                self?.handleProcessingTask(task)
            }

            logger.info(
                "Background tasks registered: appRefresh, processing",
                category: logCategory
            )
        }
    #endif

    // MARK: - Scheduling

    /// Schedule background updates based on current settings
    public func scheduleBackgroundUpdates() {
        Task {
            let manager = FilterUpdateManager.shared
            let isEnabled = await manager.isAutoUpdateEnabled
            let intervalHours = await manager.updateIntervalHours

            if isEnabled {
                #if os(iOS) || os(visionOS)
                    scheduleIOSBackgroundTasks(intervalHours: intervalHours)
                #elseif os(macOS)
                    await scheduleMacOSBackgroundActivity(
                        intervalHours: intervalHours
                    )
                #endif
            } else {
                #if os(iOS) || os(visionOS)
                    cancelIOSScheduledUpdates()
                #elseif os(macOS)
                    await cancelMacOSScheduledUpdates()
                #endif
            }
        }
    }

    /// Cancel all scheduled background updates
    public func cancelScheduledUpdates() {
        #if os(iOS) || os(visionOS)
            cancelIOSScheduledUpdates()
        #elseif os(macOS)
            Task { @MainActor in
                cancelMacOSScheduledUpdates()
            }
        #endif
    }

    #if os(iOS) || os(visionOS)
        private func cancelIOSScheduledUpdates() {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: TaskIdentifier.appRefresh
            )
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: TaskIdentifier.processing
            )
            logger.info(
                "Cancelled iOS/visionOS background tasks",
                category: logCategory
            )
        }
    #endif

    #if os(macOS)
        @MainActor
        private func cancelMacOSScheduledUpdates() {
            backgroundActivity?.invalidate()
            backgroundActivity = nil
            periodicTimer?.invalidate()
            periodicTimer = nil
            logger.info(
                "Cancelled macOS background activity",
                category: logCategory
            )
        }
    #endif

    // MARK: - iOS/visionOS Implementation

    #if os(iOS) || os(visionOS)
        private func scheduleIOSBackgroundTasks(intervalHours: Double) {
            // Schedule app refresh task (lighter weight, more frequent)
            let refreshRequest = BGAppRefreshTaskRequest(
                identifier: TaskIdentifier.appRefresh
            )
            // Request at 75% of interval (iOS has discretion on actual timing)
            refreshRequest.earliestBeginDate = Date(
                timeIntervalSinceNow: intervalHours * 3600 * 0.75
            )

            // Schedule processing task (heavier weight, less frequent)
            let processingRequest = BGProcessingTaskRequest(
                identifier: TaskIdentifier.processing
            )
            processingRequest.earliestBeginDate = Date(
                timeIntervalSinceNow: intervalHours * 3600
            )
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false

            do {
                try BGTaskScheduler.shared.submit(refreshRequest)
                logger.info(
                    "Scheduled app refresh task for \(refreshRequest.earliestBeginDate?.description ?? "soon")",
                    category: logCategory
                )
            } catch {
                logger.error(
                    "Failed to schedule app refresh task: \(error.localizedDescription)",
                    category: logCategory
                )
            }

            do {
                try BGTaskScheduler.shared.submit(processingRequest)
                logger.info(
                    "Scheduled processing task for \(processingRequest.earliestBeginDate?.description ?? "soon")",
                    category: logCategory
                )
            } catch {
                logger.error(
                    "Failed to schedule processing task: \(error.localizedDescription)",
                    category: logCategory
                )
            }
        }

        private func handleAppRefreshTask(_ task: BGAppRefreshTask) {
            let taskStartTime = Date()
            logger.info(
                "[BGAppRefreshTask] Started at \(taskStartTime)",
                category: logCategory
            )

            // Schedule next occurrence
            scheduleBackgroundUpdates()

            // Thread-safe cancellation state using actor (replaces unsafe pointer)
            let cancellationState = TaskCancellationState()
            let taskBox = UncheckedSendableBox(task)

            // Set up expiration handler
            let updateTask = Task {
                await onUpdateRequested?(true, "BGAppRefreshTask")
            }

            task.expirationHandler = { [weak self, logCategory] in
                Task {
                    await cancellationState.setCancelled()
                }
                let elapsed = Date().timeIntervalSince(taskStartTime)
                let elapsedFormatted = String(format: "%.1f", elapsed)
                self?.logger.warning(
                    "[BGAppRefreshTask] Expired after \(elapsedFormatted)s",
                    category: logCategory
                )
                updateTask.cancel()
                taskBox.value.setTaskCompleted(success: false)
                Task {
                    await FilterUpdateManager.shared.appendToLog(
                        "App refresh task expired after \(elapsedFormatted)s"
                    )
                }
            }

            Task { [weak self, logCategory = self.logCategory] in
                // Wait for update to complete.
                await updateTask.value

                // Only mark as successful if not cancelled
                let wasCancelled = await cancellationState.isCancelled()
                guard !wasCancelled else { return }

                let elapsed = Date().timeIntervalSince(taskStartTime)
                let elapsedFormatted = String(format: "%.1f", elapsed)
                self?.logger.info(
                    "[BGAppRefreshTask] Completed successfully in \(elapsedFormatted)s",
                    category: logCategory
                )
                taskBox.value.setTaskCompleted(success: true)
            }
        }

        private func handleProcessingTask(_ task: BGProcessingTask) {
            let taskStartTime = Date()
            logger.info(
                "[BGProcessingTask] Started at \(taskStartTime)",
                category: logCategory
            )

            // Schedule next occurrence
            scheduleBackgroundUpdates()

            // Thread-safe cancellation state using actor (replaces unsafe pointer)
            let cancellationState = TaskCancellationState()
            let taskBox = UncheckedSendableBox(task)

            // Set up expiration handler
            let updateTask = Task {
                await onUpdateRequested?(true, "BGProcessingTask")
            }

            task.expirationHandler = { [weak self, logCategory] in
                Task {
                    await cancellationState.setCancelled()
                }
                let elapsed = Date().timeIntervalSince(taskStartTime)
                let elapsedFormatted = String(format: "%.1f", elapsed)
                self?.logger.warning(
                    "[BGProcessingTask] Expired after \(elapsedFormatted)s",
                    category: logCategory
                )
                updateTask.cancel()
                taskBox.value.setTaskCompleted(success: false)
                Task {
                    await FilterUpdateManager.shared.appendToLog(
                        "Processing task expired after \(elapsedFormatted)s"
                    )
                }
            }

            Task { [weak self, logCategory = self.logCategory] in
                // Wait for update to complete.
                await updateTask.value

                // Only mark as successful if not cancelled
                let wasCancelled = await cancellationState.isCancelled()
                guard !wasCancelled else { return }

                let elapsed = Date().timeIntervalSince(taskStartTime)
                let elapsedFormatted = String(format: "%.1f", elapsed)
                self?.logger.info(
                    "[BGProcessingTask] Completed successfully in \(elapsedFormatted)s",
                    category: logCategory
                )
                taskBox.value.setTaskCompleted(success: true)
            }
        }
    #endif

    // MARK: - macOS Implementation

    #if os(macOS)
        @MainActor
        private func scheduleMacOSBackgroundActivity(intervalHours: Double) {
            // Cancel existing activity
            backgroundActivity?.invalidate()
            periodicTimer?.invalidate()

            // Create background activity scheduler
            let activity = NSBackgroundActivityScheduler(
                identifier: TaskIdentifier.macOSActivity
            )
            activity.repeats = true
            activity.interval = intervalHours * 3600
            activity.tolerance = min(intervalHours * 3600 * 0.2, 3600)  // 20% tolerance, max 1 hour
            activity.qualityOfService = .utility

            activity.schedule { [weak self] completion in
                guard let self = self else {
                    completion(.finished)
                    return
                }

                self.logger.info(
                    "Background activity triggered",
                    category: logCategory
                )

                Task {
                    await self.onUpdateRequested?(
                        false,
                        "NSBackgroundActivityScheduler"
                    )
                    completion(.finished)
                }
            }

            backgroundActivity = activity
            logger.info(
                "Scheduled macOS background activity with interval \(intervalHours)h",
                category: logCategory
            )

            // Also set up periodic timer for when app is active
            setupPeriodicTimer()
        }

        @MainActor
        private func setupPeriodicTimer() {
            periodicTimer?.invalidate()

            periodicTimer = Timer.scheduledTimer(
                withTimeInterval: Defaults.periodicTimerInterval,
                repeats: true
            ) { [weak self] _ in
                Task {
                    await self?.onUpdateRequested?(false, "PeriodicTimer")
                }
            }
        }
    #endif

    // MARK: - Manual Triggers

    /// Trigger an opportunistic update (respects timing constraints)
    public func triggerOpportunisticUpdate(source: String = "Manual") {
        Task {
            await onUpdateRequested?(false, source)
        }
    }

    /// Trigger a forced update (ignores timing constraints)
    public func triggerForcedUpdate(source: String = "Manual") {
        Task {
            await onUpdateRequested?(true, source)
        }
    }

    // MARK: - App Lifecycle Hooks

    /// Call when app finishes launching
    public func handleAppLaunch() {
        logger.info(
            "App launched - checking for opportunistic update",
            category: logCategory
        )
        triggerOpportunisticUpdate(source: "AppLaunch")
    }

    /// Call when app becomes active (foreground)
    public func handleAppBecameActive() {
        logger.debug("App became active", category: logCategory)

        Task {
            let status = await FilterUpdateManager.shared.getStatus()

            guard status.isEnabled else {
                logger.debug(
                    "Auto-update disabled, skipping active check",
                    category: logCategory
                )
                return
            }

            // Log current status
            let lastCheckInfo =
                status.lastCheckTime.map { date -> String in
                    let elapsed = Date().timeIntervalSince(date)
                    let hours = Int(elapsed / 3600)
                    let minutes = Int(
                        (elapsed.truncatingRemainder(dividingBy: 3600)) / 60
                    )
                    return "\(hours)h \(minutes)m ago"
                } ?? "never"

            logger.debug(
                "Update status: enabled=\(status.isEnabled), running=\(status.isRunning), lastCheck=\(lastCheckInfo), overdue=\(status.isOverdue)",
                category: logCategory
            )

            // Force update if significantly overdue
            if status.isOverdue {
                logger.info(
                    "Update overdue - forcing update",
                    category: logCategory
                )
                triggerForcedUpdate(source: "AppBecameActive-Overdue")
            } else if let nextTime = status.nextScheduledTime,
                Date().addingTimeInterval(300) >= nextTime
            {
                // Due within 5 minutes - trigger now
                logger.info(
                    "Update due within 5 minutes - triggering opportunistic update",
                    category: logCategory
                )
                triggerOpportunisticUpdate(source: "AppBecameActive-DueSoon")
            } else {
                logger.debug(
                    "No update needed at this time",
                    category: logCategory
                )
            }
        }
    }

    /// Call when app enters background (iOS only)
    public func handleAppEnteredBackground() {
        #if os(iOS) || os(visionOS)
            // Ensure background tasks are scheduled
            scheduleBackgroundUpdates()
        #endif
    }
}

// MARK: - Debug Helpers

#if DEBUG
    extension FilterUpdateScheduler {
        /// Simulate a background task trigger (debug only)
        public func simulateBackgroundTask() {
            logger.info("Simulating background task", category: logCategory)
            triggerForcedUpdate(source: "DebugSimulation")
        }

        /// Get pending task requests (iOS only, debug)
        #if os(iOS) || os(visionOS)
            public func getPendingTaskRequests() async -> [BGTaskRequest] {
                await BGTaskScheduler.shared.pendingTaskRequests()
            }
        #endif
    }
#endif

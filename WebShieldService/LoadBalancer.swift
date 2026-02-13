//
//  LoadBalancer.swift
//  WebShieldService
//
//  Load balancer for distributing filter rules across content blocker extensions.
//

import Foundation

// MARK: - Load Balancer Types

/// Information about a filter for load balancing purposes
public struct FilterAssignmentInfo: Sendable, Hashable {
    public let filterID: String
    public let estimatedRuleCount: Int

    public init(filterID: String, estimatedRuleCount: Int) {
        self.filterID = filterID
        self.estimatedRuleCount = estimatedRuleCount
    }
}

/// Assignment of filters to a specific content blocker
public struct BlockerAssignment: Sendable {
    public let blocker: ContentBlockerCategory
    public var filters: [FilterAssignmentInfo]
    public var estimatedRuleCount: Int
    public var actualRuleCount: Int?

    public init(
        blocker: ContentBlockerCategory,
        filters: [FilterAssignmentInfo] = [],
        estimatedRuleCount: Int = 0,
        actualRuleCount: Int? = nil
    ) {
        self.blocker = blocker
        self.filters = filters
        self.estimatedRuleCount = estimatedRuleCount
        self.actualRuleCount = actualRuleCount
    }
}

// MARK: - Load Balancer

/// Thread-safe actor managing distribution of filter rules across content blocker extensions.
///
/// Uses a "least-filled first" greedy algorithm to distribute filters evenly:
/// 1. Sort filters by rule count (largest first) for better bin-packing
/// 2. Assign each filter to the blocker with fewest estimated rules
/// 3. Track actual rule counts after conversion for monitoring
public actor LoadBalancer {

    // MARK: - Singleton

    public static let shared = LoadBalancer()

    // MARK: - Constants

    /// Safari's hard limit per content blocker extension
    public static let ruleLimit = 150_000

    /// Warning threshold at 80% capacity
    public static let warningThreshold = 120_000

    // MARK: - Properties

    private let logger = WebShieldLogger.shared
    private let logCategory = "LoadBalancer"

    /// Current rule counts per blocker (actual counts from last conversion)
    public private(set) var ruleCountsByBlocker: [ContentBlockerCategory: Int] = [:]

    /// Set of blockers approaching the limit (80%+)
    public private(set) var blockersApproachingLimit: Set<ContentBlockerCategory> = []

    /// Set of blockers that exceeded the limit
    public private(set) var blockersExceedingLimit: Set<ContentBlockerCategory> = []

    /// Last distribution result for debugging/UI
    public private(set) var lastDistribution: [ContentBlockerCategory: BlockerAssignment] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Distribution Algorithm

    /// Distribute filters across blockers using least-filled-first algorithm.
    ///
    /// Algorithm:
    /// 1. Sort filters by estimatedRuleCount descending (largest first)
    /// 2. For each filter, assign to the blocker with minimum current load
    /// 3. Update estimated load for that blocker
    ///
    /// This greedy bin-packing heuristic works well for filter distribution
    /// and ensures even utilization across all available blockers.
    ///
    /// - Parameter filters: Array of filters with their estimated rule counts
    /// - Returns: Dictionary mapping each blocker to its assigned filters
    public func distributeFilters(
        _ filters: [FilterAssignmentInfo]
    ) -> [ContentBlockerCategory: [FilterAssignmentInfo]] {
        // Sort filters by rule count descending (largest first for better packing)
        let sortedFilters = filters.sorted { lhs, rhs in
            if lhs.estimatedRuleCount != rhs.estimatedRuleCount {
                return lhs.estimatedRuleCount > rhs.estimatedRuleCount
            }
            // Tiebreaker: sort by ID for deterministic results
            return lhs.filterID < rhs.filterID
        }

        // Initialize tracking for all blockers
        var estimatedRulesByBlocker: [ContentBlockerCategory: Int] = [:]
        var filtersByBlocker: [ContentBlockerCategory: [FilterAssignmentInfo]] = [:]

        for blocker in ContentBlockerCategory.allCases {
            estimatedRulesByBlocker[blocker] = 0
            filtersByBlocker[blocker] = []
        }

        // Distribute each filter to the least-filled blocker
        for filter in sortedFilters {
            // Find the blocker with minimum estimated rules
            guard let leastFilledBlocker = ContentBlockerCategory.allCases.min(by: { lhs, rhs in
                let lhsCount = estimatedRulesByBlocker[lhs] ?? 0
                let rhsCount = estimatedRulesByBlocker[rhs] ?? 0
                if lhsCount != rhsCount {
                    return lhsCount < rhsCount
                }
                // Tiebreaker: prefer lower-numbered blocker for determinism
                return lhs.rawValue < rhs.rawValue
            }) else {
                logger.error("No blockers available for distribution", category: logCategory)
                break
            }

            // Assign filter to this blocker
            filtersByBlocker[leastFilledBlocker, default: []].append(filter)
            estimatedRulesByBlocker[leastFilledBlocker, default: 0] += filter.estimatedRuleCount

            logger.debug(
                "Assigned filter \(filter.filterID) (\(filter.estimatedRuleCount) rules) to blocker\(leastFilledBlocker.rawValue)",
                category: logCategory
            )
        }

        // Store distribution for debugging/UI
        lastDistribution = [:]
        for blocker in ContentBlockerCategory.allCases {
            lastDistribution[blocker] = BlockerAssignment(
                blocker: blocker,
                filters: filtersByBlocker[blocker] ?? [],
                estimatedRuleCount: estimatedRulesByBlocker[blocker] ?? 0
            )
        }

        // Log distribution summary
        let summary = ContentBlockerCategory.allCases.map { blocker in
            "blocker\(blocker.rawValue): \(filtersByBlocker[blocker]?.count ?? 0) filters, ~\(estimatedRulesByBlocker[blocker] ?? 0) rules"
        }.joined(separator: ", ")
        logger.info("Distribution: \(summary)", category: logCategory)

        return filtersByBlocker
    }

    // MARK: - Rule Count Tracking

    /// Update the actual rule count for a blocker after conversion.
    ///
    /// - Parameters:
    ///   - count: The actual Safari rule count from conversion
    ///   - blocker: The content blocker category
    public func updateActualRuleCount(_ count: Int, for blocker: ContentBlockerCategory) {
        ruleCountsByBlocker[blocker] = count

        // Update limit tracking
        if count >= Self.ruleLimit {
            blockersExceedingLimit.insert(blocker)
            blockersApproachingLimit.remove(blocker)
            logger.error(
                "Blocker\(blocker.rawValue) EXCEEDS limit: \(count)/\(Self.ruleLimit) rules",
                category: logCategory
            )
        } else if count >= Self.warningThreshold {
            blockersApproachingLimit.insert(blocker)
            blockersExceedingLimit.remove(blocker)
            logger.warning(
                "Blocker\(blocker.rawValue) approaching limit: \(count)/\(Self.ruleLimit) rules (\(Int(Double(count) / Double(Self.ruleLimit) * 100))%)",
                category: logCategory
            )
        } else {
            blockersApproachingLimit.remove(blocker)
            blockersExceedingLimit.remove(blocker)
        }

        // Update lastDistribution with actual count
        if var assignment = lastDistribution[blocker] {
            assignment.actualRuleCount = count
            lastDistribution[blocker] = assignment
        }
    }

    /// Get blockers that are approaching or exceeding the limit.
    ///
    /// - Returns: Array of blockers with warning status
    public func checkLimitWarnings() -> [(blocker: ContentBlockerCategory, count: Int, isExceeding: Bool)] {
        var warnings: [(blocker: ContentBlockerCategory, count: Int, isExceeding: Bool)] = []

        for blocker in blockersExceedingLimit {
            if let count = ruleCountsByBlocker[blocker] {
                warnings.append((blocker: blocker, count: count, isExceeding: true))
            }
        }

        for blocker in blockersApproachingLimit {
            if let count = ruleCountsByBlocker[blocker] {
                warnings.append((blocker: blocker, count: count, isExceeding: false))
            }
        }

        return warnings.sorted { $0.blocker.rawValue < $1.blocker.rawValue }
    }

    /// Get total rule count across all blockers.
    public func totalRuleCount() -> Int {
        ruleCountsByBlocker.values.reduce(0, +)
    }

    /// Get the distribution summary for UI display.
    ///
    /// - Returns: Array of blocker assignments sorted by blocker number
    public func getDistributionSummary() -> [BlockerAssignment] {
        ContentBlockerCategory.allCases.compactMap { lastDistribution[$0] }
    }

    /// Clear all tracked state (e.g., after a fresh install or reset).
    public func reset() {
        ruleCountsByBlocker = [:]
        blockersApproachingLimit = []
        blockersExceedingLimit = []
        lastDistribution = [:]
        logger.info("Load balancer state reset", category: logCategory)
    }

    // MARK: - Persistence

    private var userDefaults: UserDefaults {
        UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
    }

    private enum Keys {
        static let ruleCountsByBlocker = "loadBalancer.ruleCountsByBlocker"
    }

    /// Save rule counts to persistent storage.
    public func saveState() {
        let counts = ruleCountsByBlocker.reduce(into: [String: Int]()) { result, pair in
            result[String(pair.key.rawValue)] = pair.value
        }
        userDefaults.set(counts, forKey: Keys.ruleCountsByBlocker)
        logger.debug("Saved load balancer state", category: logCategory)
    }

    /// Load rule counts from persistent storage.
    public func loadState() {
        guard let counts = userDefaults.dictionary(forKey: Keys.ruleCountsByBlocker) as? [String: Int] else {
            return
        }

        for (key, value) in counts {
            if let rawValue = Int(key),
               let blocker = ContentBlockerCategory(rawValue: rawValue) {
                ruleCountsByBlocker[blocker] = value

                // Update warning sets
                if value >= Self.ruleLimit {
                    blockersExceedingLimit.insert(blocker)
                } else if value >= Self.warningThreshold {
                    blockersApproachingLimit.insert(blocker)
                }
            }
        }

        logger.debug("Loaded load balancer state: \(ruleCountsByBlocker.count) blockers", category: logCategory)
    }
}

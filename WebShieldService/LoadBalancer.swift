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

/// Raw filter list contents to be assigned across content blocker extensions.
public struct FilterRuleContent: Sendable, Hashable {
    public let filterID: String
    public let content: String
    public let estimatedRuleCount: Int?

    public init(
        filterID: String,
        content: String,
        estimatedRuleCount: Int? = nil
    ) {
        self.filterID = filterID
        self.content = content
        self.estimatedRuleCount = estimatedRuleCount
    }
}

/// Combined filter-list input assigned to a specific content blocker extension.
public struct RuleShardAssignment: Sendable {
    public let blocker: ContentBlockerCategory
    public let rulesText: String
    public let filters: [FilterAssignmentInfo]
    public let estimatedRuleCount: Int
    public let normalRuleCount: Int
    public let affinityRuleCount: Int
    public let duplicatedExceptionRuleCount: Int

    public var isEmpty: Bool {
        rulesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        blocker: ContentBlockerCategory,
        rulesText: String = "",
        filters: [FilterAssignmentInfo] = [],
        estimatedRuleCount: Int = 0,
        normalRuleCount: Int = 0,
        affinityRuleCount: Int = 0,
        duplicatedExceptionRuleCount: Int = 0
    ) {
        self.blocker = blocker
        self.rulesText = rulesText
        self.filters = filters
        self.estimatedRuleCount = estimatedRuleCount
        self.normalRuleCount = normalRuleCount
        self.affinityRuleCount = affinityRuleCount
        self.duplicatedExceptionRuleCount = duplicatedExceptionRuleCount
    }
}

public enum RuleShardingError: Error, LocalizedError, Sendable {
    case duplicatedExceptionsExceedLimit(
        exceptionRules: Int,
        whitelistRules: Int,
        ruleLimit: Int
    )
    case ruleCapacityExceeded(
        normalRules: Int,
        capacity: Int,
        ruleLimit: Int,
        blockers: Int
    )
    case conversionValidationExceeded(ruleLimit: Int, blockers: [ContentBlockerCategory])

    public var errorDescription: String? {
        switch self {
        case .duplicatedExceptionsExceedLimit(
            let exceptionRules,
            let whitelistRules,
            let ruleLimit
        ):
            return "Exception and whitelist rules need \(exceptionRules + whitelistRules) slots per blocker, exceeding the \(ruleLimit)-rule limit"
        case .ruleCapacityExceeded(
            let normalRules,
            let capacity,
            let ruleLimit,
            let blockers
        ):
            return "Filter rules need \(normalRules) normal-rule slots, but \(blockers) blockers at \(ruleLimit) rules can hold \(capacity) after exception duplication"
        case .conversionValidationExceeded(let ruleLimit, let blockers):
            let names = blockers
                .sorted { $0.rawValue < $1.rawValue }
                .map { "blocker\($0.rawValue)" }
                .joined(separator: ", ")
            return "Distributed filter inputs exceeded the \(ruleLimit)-rule limit for \(names)"
        }
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

    /// Safari's hard limit per content blocker extension for the active platform.
    public static var ruleLimit: Int {
        ContentBlockerRuleLimit.currentPlatformLimit
    }

    /// Warning threshold at 80% capacity
    public static var warningThreshold: Int {
        ContentBlockerRuleLimit.currentPlatformWarningThreshold
    }

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

    /// Assign whole filter lists across content blocker extensions.
    ///
    /// Base filter lists are assigned by descending source-rule count to the
    /// least-filled blocker. `!#safari_cb_affinity` sections can additionally
    /// route selected rules to named or numeric blocker slots.
    public func distributeRuleContent(
        _ filters: [FilterRuleContent],
        ruleLimit: Int = ContentBlockerRuleLimit.currentPlatformLimit,
        whitelistRuleReserve: Int = 0
    ) throws -> [ContentBlockerCategory: RuleShardAssignment] {
        let blockers = ContentBlockerCategory.allCases.sorted {
            $0.rawValue < $1.rawValue
        }
        let orderedFilters = Self.orderedForDistribution(filters)
        let baseAssignments = Self.distributeWholeFilters(
            orderedFilters,
            across: blockers
        )
        var mutableShards = Dictionary(
            uniqueKeysWithValues: blockers.map {
                ($0, MutableRuleShard(blocker: $0))
            }
        )

        for blocker in blockers {
            let baseFilterIDs = Set(
                baseAssignments[blocker, default: []].map(\.filterID)
            )

            for filter in orderedFilters {
                let includeBaseRules = baseFilterIDs.contains(filter.filterID)
                guard includeBaseRules
                    || filter.content.contains(Self.affinityDirectivePrefix)
                else {
                    continue
                }

                let contribution = Self.filteredContribution(
                    from: filter.content,
                    includeBaseRules: includeBaseRules,
                    blocker: blocker,
                    allBlockers: blockers
                )
                guard !contribution.isEmpty else { continue }

                mutableShards[blocker]?.ruleChunks.append(contribution.text)
                mutableShards[blocker]?.normalRuleCount +=
                    contribution.baseRuleCount
                mutableShards[blocker]?.affinityRuleCount +=
                    contribution.affinityRuleCount
                mutableShards[blocker]?.filterRuleCounts[
                    filter.filterID,
                    default: 0
                ] += contribution.totalRuleCount
            }
        }

        var assignments: [ContentBlockerCategory: RuleShardAssignment] = [:]
        for blocker in blockers {
            guard let shard = mutableShards[blocker], !shard.isEmpty else {
                assignments[blocker] = RuleShardAssignment(blocker: blocker)
                continue
            }

            let filters = shard.filterRuleCounts
                .map {
                    FilterAssignmentInfo(
                        filterID: $0.key,
                        estimatedRuleCount: $0.value
                    )
                }
                .sorted {
                    if $0.estimatedRuleCount != $1.estimatedRuleCount {
                        return $0.estimatedRuleCount > $1.estimatedRuleCount
                    }
                    return $0.filterID < $1.filterID
                }
            let rulesText = shard.ruleChunks.joined(separator: "\n")
            let estimatedRuleCount = shard.normalRuleCount
                + shard.affinityRuleCount

            assignments[blocker] = RuleShardAssignment(
                blocker: blocker,
                rulesText: rulesText,
                filters: filters,
                estimatedRuleCount: estimatedRuleCount,
                normalRuleCount: shard.normalRuleCount,
                affinityRuleCount: shard.affinityRuleCount,
                duplicatedExceptionRuleCount: 0
            )
        }

        lastDistribution = [:]
        for blocker in blockers {
            let assignment = assignments[blocker]
                ?? RuleShardAssignment(blocker: blocker)
            lastDistribution[blocker] = BlockerAssignment(
                blocker: blocker,
                filters: assignment.filters,
                estimatedRuleCount: assignment.estimatedRuleCount
            )
        }

        let summary = blockers.map { blocker in
            let assignment = assignments[blocker]
                ?? RuleShardAssignment(blocker: blocker)
            return "blocker\(blocker.rawValue): \(assignment.normalRuleCount) base + \(assignment.affinityRuleCount) affinity"
        }.joined(separator: ", ")
        logger.info("Filter distribution: \(summary)", category: logCategory)

        return assignments
    }

    public static func orderedForDistribution(
        _ filters: [FilterRuleContent]
    ) -> [FilterRuleContent] {
        filters.sorted { lhs, rhs in
            let lhsCount = estimatedRuleCount(for: lhs)
            let rhsCount = estimatedRuleCount(for: rhs)
            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }
            return lhs.filterID < rhs.filterID
        }
    }

    private struct MutableRuleShard {
        let blocker: ContentBlockerCategory
        var ruleChunks: [String] = []
        var filterRuleCounts: [String: Int] = [:]
        var normalRuleCount = 0
        var affinityRuleCount = 0

        var isEmpty: Bool {
            ruleChunks.allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private struct FilteredContribution {
        let text: String
        let baseRuleCount: Int
        let affinityRuleCount: Int

        var totalRuleCount: Int {
            baseRuleCount + affinityRuleCount
        }

        var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private enum AffinityDestination {
        case baseRulesOnly
        case targetSlots(Set<ContentBlockerCategory>)
    }

    private enum AffinityDirective {
        case start(AffinityDestination)
        case end
    }

    private static let affinityDirectivePrefix = "!#safari_cb_affinity"

    private static func distributeWholeFilters(
        _ filters: [FilterRuleContent],
        across blockers: [ContentBlockerCategory]
    ) -> [ContentBlockerCategory: [FilterRuleContent]] {
        guard !blockers.isEmpty else { return [:] }

        var filtersByBlocker = Dictionary(
            uniqueKeysWithValues: blockers.map { ($0, [FilterRuleContent]()) }
        )
        var estimatedRulesByBlocker = Dictionary(
            uniqueKeysWithValues: blockers.map { ($0, 0) }
        )

        for filter in filters {
            guard let destination = blockers.min(by: { lhs, rhs in
                let lhsCount = estimatedRulesByBlocker[lhs] ?? 0
                let rhsCount = estimatedRulesByBlocker[rhs] ?? 0
                if lhsCount != rhsCount {
                    return lhsCount < rhsCount
                }
                return lhs.rawValue < rhs.rawValue
            }) else {
                break
            }

            filtersByBlocker[destination, default: []].append(filter)
            estimatedRulesByBlocker[destination, default: 0] +=
                estimatedRuleCount(for: filter)
        }

        return filtersByBlocker
    }

    private static func filteredContribution(
        from content: String,
        includeBaseRules: Bool,
        blocker: ContentBlockerCategory,
        allBlockers: [ContentBlockerCategory]
    ) -> FilteredContribution {
        let availableBlockers = Set(allBlockers)
        var destinationStack: [AffinityDestination] = []
        var includedLines: [String] = []
        var baseRuleCount = 0
        var affinityRuleCount = 0

        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let directive = parseAffinityDirective(
                trimmed,
                availableBlockers: availableBlockers
            ) {
                switch directive {
                case .start(let destination):
                    destinationStack.append(destination)
                case .end:
                    if !destinationStack.isEmpty {
                        destinationStack.removeLast()
                    }
                }
                return
            }

            let shouldInclude: Bool
            let isAffinityRule: Bool
            if let destination = destinationStack.last {
                switch destination {
                case .baseRulesOnly:
                    shouldInclude = includeBaseRules
                    isAffinityRule = false
                case .targetSlots(let slots):
                    shouldInclude = slots.contains(blocker)
                    isAffinityRule = true
                }
            } else {
                shouldInclude = includeBaseRules
                isAffinityRule = false
            }

            guard shouldInclude else { return }

            includedLines.append(line)
            guard isEffectiveRuleLine(trimmed) else { return }

            if isAffinityRule {
                affinityRuleCount += 1
            } else {
                baseRuleCount += 1
            }
        }

        return FilteredContribution(
            text: includedLines.joined(separator: "\n"),
            baseRuleCount: baseRuleCount,
            affinityRuleCount: affinityRuleCount
        )
    }

    public static func filteredContent(
        from content: String,
        includeBaseRules: Bool,
        blocker: ContentBlockerCategory,
        allBlockers: [ContentBlockerCategory] = ContentBlockerCategory
            .allCases
    ) -> String {
        filteredContribution(
            from: content,
            includeBaseRules: includeBaseRules,
            blocker: blocker,
            allBlockers: allBlockers
        ).text
    }

    private static func parseAffinityDirective(
        _ trimmed: String,
        availableBlockers: Set<ContentBlockerCategory>
    ) -> AffinityDirective? {
        guard trimmed.hasPrefix(affinityDirectivePrefix) else { return nil }

        if trimmed == affinityDirectivePrefix {
            return .end
        }

        let suffix = String(trimmed.dropFirst(affinityDirectivePrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard suffix.first == "(", suffix.last == ")" else {
            return .start(.baseRulesOnly)
        }

        let tokenBody = suffix.dropFirst().dropLast()
        let tokens = tokenBody.split(
            separator: ",",
            omittingEmptySubsequences: true
        )
        var targetSlots: Set<ContentBlockerCategory> = []

        for token in tokens {
            let normalized = token
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            targetSlots.formUnion(
                mappedBlockers(
                    for: normalized,
                    availableBlockers: availableBlockers
                )
            )
        }

        guard !targetSlots.isEmpty else {
            return .start(.baseRulesOnly)
        }

        return .start(.targetSlots(targetSlots))
    }

    private static func mappedBlockers(
        for token: String,
        availableBlockers: Set<ContentBlockerCategory>
    ) -> Set<ContentBlockerCategory> {
        if token == "all" {
            return availableBlockers
        }

        if let rawValue = Int(token),
            let blocker = ContentBlockerCategory(rawValue: rawValue),
            availableBlockers.contains(blocker)
        {
            return [blocker]
        }

        let rawValue: Int?
        switch token {
        case "ads":
            rawValue = 1
        case "privacy":
            rawValue = 2
        case "security":
            rawValue = 3
        case "multipurpose":
            rawValue = 4
        case "cookies":
            rawValue = 5
        case "social":
            rawValue = 6
        case "annoyances":
            rawValue = 7
        case "regional":
            rawValue = 8
        case "experimental":
            rawValue = 9
        default:
            rawValue = nil
        }

        guard let rawValue,
            let blocker = ContentBlockerCategory(rawValue: rawValue),
            availableBlockers.contains(blocker)
        else {
            return []
        }

        return [blocker]
    }

    private static func estimatedRuleCount(for filter: FilterRuleContent) -> Int {
        if let estimatedRuleCount = filter.estimatedRuleCount,
            estimatedRuleCount >= 0
        {
            return estimatedRuleCount
        }

        return countEffectiveRules(in: filter.content)
    }

    private static func countEffectiveRules(in content: String) -> Int {
        content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .count(where: isEffectiveRuleLine)
    }

    private static func isEffectiveRuleLine(_ trimmed: String) -> Bool {
        !trimmed.isEmpty
            && !trimmed.hasPrefix("!")
            && !trimmed.hasPrefix("[")
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
        if count > Self.ruleLimit {
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
                if value > Self.ruleLimit {
                    blockersExceedingLimit.insert(blocker)
                } else if value >= Self.warningThreshold {
                    blockersApproachingLimit.insert(blocker)
                }
            }
        }

        logger.debug("Loaded load balancer state: \(ruleCountsByBlocker.count) blockers", category: logCategory)
    }
}

import Testing
import WebShieldService

@Suite("LoadBalancer", .serialized)
struct LoadBalancerTests {
    @Test func ordersFiltersByEstimatedRuleCountThenID() {
        let ordered = LoadBalancer.orderedForDistribution([
            FilterRuleContent(filterID: "b", content: "b", estimatedRuleCount: 2),
            FilterRuleContent(filterID: "a", content: "a", estimatedRuleCount: 2),
            FilterRuleContent(filterID: "c", content: "c", estimatedRuleCount: 5),
        ])

        #expect(ordered.map(\.filterID) == ["c", "a", "b"])
    }

    @Test func distributesWholeFiltersByLeastFilledBlocker() async throws {
        let loadBalancer = LoadBalancer.shared
        await loadBalancer.reset()

        let distribution = try await loadBalancer.distributeRuleContent([
            FilterRuleContent(filterID: "large", content: "large", estimatedRuleCount: 100),
            FilterRuleContent(filterID: "medium", content: "medium", estimatedRuleCount: 80),
            FilterRuleContent(filterID: "small", content: "small", estimatedRuleCount: 60),
        ])

        #expect(distribution[.blocker1]?.filters.map(\.filterID) == ["large"])
        #expect(distribution[.blocker2]?.filters.map(\.filterID) == ["medium"])
        #expect(distribution[.blocker3]?.filters.map(\.filterID) == ["small"])
        #expect(distribution[.blocker4]?.isEmpty == true)
    }

    @Test func equalSizedFiltersUseStableIDTieBreak() async throws {
        let loadBalancer = LoadBalancer.shared
        await loadBalancer.reset()

        let distribution = try await loadBalancer.distributeRuleContent([
            FilterRuleContent(filterID: "b", content: "b", estimatedRuleCount: 10),
            FilterRuleContent(filterID: "a", content: "a", estimatedRuleCount: 10),
        ])

        #expect(distribution[.blocker1]?.filters.map(\.filterID) == ["a"])
        #expect(distribution[.blocker2]?.filters.map(\.filterID) == ["b"])
    }

    @Test func emptyInputReturnsEmptyAssignmentsForAllBlockers() async throws {
        let loadBalancer = LoadBalancer.shared
        await loadBalancer.reset()

        let distribution = try await loadBalancer.distributeRuleContent([])

        #expect(distribution.count == ContentBlockerCategory.allCases.count)
        let allAssignmentsAreEmpty = distribution.values.reduce(true) { partialResult, assignment in
            partialResult && assignment.isEmpty
        }
        #expect(allAssignmentsAreEmpty)
    }

    @Test func namedAffinityTokensMapToWebShieldSlots() {
        let content = """
        base
        !#safari_cb_affinity(ads,privacy,security,multipurpose,cookies,social,annoyances,regional,experimental)
        routed
        !#safari_cb_affinity
        after
        """

        for blocker in ContentBlockerCategory.allCases {
            let filtered = LoadBalancer.filteredContent(
                from: content,
                includeBaseRules: false,
                blocker: blocker
            )
            #expect(filtered == "routed")
        }
    }

    @Test func numericAndAllAffinityTokensAreSupported() {
        let numeric = """
        !#safari_cb_affinity(1,9)
        edge
        !#safari_cb_affinity
        """
        let all = """
        !#safari_cb_affinity(all)
        every
        !#safari_cb_affinity
        """

        #expect(
            LoadBalancer.filteredContent(
                from: numeric,
                includeBaseRules: false,
                blocker: .blocker1
            ) == "edge"
        )
        #expect(
            LoadBalancer.filteredContent(
                from: numeric,
                includeBaseRules: false,
                blocker: .blocker5
            ).isEmpty
        )
        #expect(
            LoadBalancer.filteredContent(
                from: numeric,
                includeBaseRules: false,
                blocker: .blocker9
            ) == "edge"
        )

        for blocker in ContentBlockerCategory.allCases {
            #expect(
                LoadBalancer.filteredContent(
                    from: all,
                    includeBaseRules: false,
                    blocker: blocker
                ) == "every"
            )
        }
    }

    @Test func nestedAffinityUsesInnermostDestination() {
        let content = """
        !#safari_cb_affinity(ads)
        ads-1
        !#safari_cb_affinity(privacy)
        privacy-1
        !#safari_cb_affinity
        ads-2
        !#safari_cb_affinity
        """

        #expect(
            LoadBalancer.filteredContent(
                from: content,
                includeBaseRules: false,
                blocker: .blocker1
            ) == "ads-1\nads-2"
        )
        #expect(
            LoadBalancer.filteredContent(
                from: content,
                includeBaseRules: false,
                blocker: .blocker2
            ) == "privacy-1"
        )
    }

    @Test func unterminatedAffinityRunsToEndOfFilter() {
        let content = """
        base
        !#safari_cb_affinity(regional)
        regional-1
        regional-2
        """

        #expect(
            LoadBalancer.filteredContent(
                from: content,
                includeBaseRules: false,
                blocker: .blocker8
            ) == "regional-1\nregional-2"
        )
    }

    @Test func unknownAffinityTokensFallBackToBaseRulesOnly() {
        let content = """
        !#safari_cb_affinity(unknown)
        base-only
        !#safari_cb_affinity
        """

        #expect(
            LoadBalancer.filteredContent(
                from: content,
                includeBaseRules: true,
                blocker: .blocker1
            ) == "base-only"
        )
        #expect(
            LoadBalancer.filteredContent(
                from: content,
                includeBaseRules: false,
                blocker: .blocker1
            ).isEmpty
        )
    }

    @Test func mixedBaseAndAffinityContributionsStayWholeFilterBased() async throws {
        let loadBalancer = LoadBalancer.shared
        await loadBalancer.reset()

        let distribution = try await loadBalancer.distributeRuleContent([
            FilterRuleContent(filterID: "large", content: "large-base", estimatedRuleCount: 100),
            FilterRuleContent(
                filterID: "affinity",
                content: """
                affinity-base
                !#safari_cb_affinity(ads)
                affinity-routed
                !#safari_cb_affinity
                """,
                estimatedRuleCount: 1
            ),
        ])

        #expect(distribution[.blocker1]?.rulesText == "large-base\naffinity-routed")
        #expect(Set(distribution[.blocker1]?.filters.map(\.filterID) ?? []) == ["large", "affinity"])
        #expect(distribution[.blocker2]?.rulesText == "affinity-base")
        #expect(distribution[.blocker2]?.filters.map(\.filterID) == ["affinity"])
    }

    @Test func validationPreflightReceivesWholeFilterText() async throws {
        let loadBalancer = LoadBalancer.shared
        await loadBalancer.reset()
        let wholeFilter = """
        ||example.com^
        ||example.net^
        """
        var preflightInputs: [String] = []

        let distribution = try await ContentBlockerService
            .validatedRuleDistribution(
                [
                    FilterRuleContent(
                        filterID: "whole-filter",
                        content: wholeFilter,
                        estimatedRuleCount: 2
                    )
                ],
                loadBalancer: loadBalancer,
                ruleLimit: 100,
                whitelistRuleReserve: 0,
                conversionPreflight: { rules, _ in
                    preflightInputs.append(rules)
                    return ContentBlockerService.FilterConversionResult(
                        totalSourceRuleCount: 2,
                        safariRulesCount: 2,
                        advancedRulesText: nil
                    )
                }
            )

        #expect(preflightInputs == [wholeFilter])
        #expect(distribution[.blocker1]?.rulesText == wholeFilter)
    }
}

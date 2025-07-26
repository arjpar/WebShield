internal import FilterEngine
import Foundation
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FilterList.order, order: .forward) private var filterLists:
        [FilterList]
    @State private var selectedCategory: FilterListCategory? = .all
    @State private var isUpdating = false
    @State private var showingLogs = false
    @State private var showingImport = false
    @State private var showingSettings = false
    @State private var showingHelp = false
    @State private var progress: Double = 0
    @State private var currentList: Int = 0
    private let filterListProcessor = FilterListProcessor()
    @State private var totalLists: Int = 0
    @State private var columnVisibility = NavigationSplitViewVisibility
        .automatic
    @EnvironmentObject private var contentBlockerState: ContentBlockerState
    @EnvironmentObject private var advancedExtensionState: WebExtensionState
    @EnvironmentObject private var refreshErrorViewModel: RefreshErrorViewModel
    @StateObject private var extensionVM: ExtensionCheckViewModel

    init(
        contentBlockerState: ContentBlockerState? = nil,
        advancedExtensionState: WebExtensionState? = nil
    ) {
        let refreshErrorViewModel = RefreshErrorViewModel()
        _extensionVM = StateObject(
            wrappedValue: ExtensionCheckViewModel(
                contentBlockerState: contentBlockerState
                    ?? ContentBlockerState(
                        refreshErrorViewModel: refreshErrorViewModel
                    ),
                advancedExtensionState: advancedExtensionState
                    ?? WebExtensionState()
            )
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedCategory: $selectedCategory)
        } detail: {
            detailView
        }
        .onAppear {
            Task {
                await extensionVM.checkExtensions()
            }
        }
        .sheet(isPresented: $extensionVM.showEnablePrompt) {
            EnableExtensionsSheet(
                missingExtensions: extensionVM.missingExtensions
            )
            // visionOS specific modifiers
            #if os(visionOS)
                .glassBackgroundEffect()
                .padding(32)
            #endif
        }

    }

    private var detailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isUpdating {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            FilterListView(category: selectedCategory ?? .all)
                .navigationTitle(selectedCategory?.rawValue ?? "All")
                .toolbar {
                    toolbarContent()
                }
                .sheet(isPresented: $showingLogs) {
                    LogsView()
                }
                .sheet(isPresented: $showingImport) {
                    ImportView()
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                }
                .sheet(isPresented: $showingHelp) {
                    HelpSheet()
                }
                .sheet(isPresented: $refreshErrorViewModel.showErrorView) {
                    ErrorView()
                        .environmentObject(refreshErrorViewModel)
                }

        }
    }

    @ToolbarContentBuilder
    private func toolbarContent() -> some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {

            Button(action: { showingHelp.toggle() }) {
                Label("Help", systemImage: "questionmark")
            }
            .help("Help")

            Button(action: { showingSettings.toggle() }) {
                Label("Settings", systemImage: "gear")
            }
            .help("Settings")

            //            PulsatingCircleButton()

            Button(action: { refreshFilters() }) {
                Label("Refresh", systemImage: "arrow.2.circlepath")
            }
            .help("Refresh Filters")
            .disabled(isUpdating)

            Button(action: { showingLogs.toggle() }) {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }
            .help("View Logs")

            Button(action: { showingImport.toggle() }) {
                Label("Import", systemImage: "plus")
            }
            .help("Import Filters")
        }
    }

    private var enabledFilterCount: Int {
        filterLists.filter { $0.isEnabled }.count
    }

    /// Summation of counts from both blockerList.json and advancedBlocking.json.
    private var totalRuleCount: Int {
        var combinedCount = 0

        // 1. blockerList.json
        if let blockerListURL = GroupContainerURL.groupContainerURL()?
            .appendingPathComponent("blockerList.json")
        {
            combinedCount += jsonArrayCount(at: blockerListURL)
        }

        // 2. advancedBlocking.json
        if let advancedBlockingURL = GroupContainerURL.groupContainerURL()?
            .appendingPathComponent("advancedBlocking.json")
        {
            combinedCount += jsonArrayCount(at: advancedBlockingURL)
        }

        return combinedCount
    }

    /// Safely decodes a file as a top-level JSON array, then returns its count.
    /// If the file is missing or invalid, returns 0.
    private func jsonArrayCount(at fileURL: URL) -> Int {
        guard
            let data = try? Data(contentsOf: fileURL),
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let array = jsonObject as? [Any]
        else {
            return 0
        }
        return array.count
    }

    private func shouldShowSection(_ category: FilterListCategory) -> Bool {
        selectedCategory == .all || category == selectedCategory
    }

    private var groupedFilterLists: [FilterListSection] {
        let categoryOrder: [FilterListCategory] = [
            .ads, .privacy, .security, .multipurpose,
            .social, .cookies, .annoyances, .regional,
            .experimental, .custom,
        ]

        let sortedLists = filterLists.sorted { $0.order < $1.order }
        var sections: [FilterListCategory: [FilterList]] = [:]

        for list in sortedLists {
            if let category = list.category {
                sections[category, default: []].append(list)
            }
        }

        return categoryOrder.compactMap { category in
            if let lists = sections[category], !lists.isEmpty {
                return FilterListSection(
                    title: category.rawValue,
                    filterLists: lists,
                    category: category
                )
            }
            return nil
        }
    }

    func refreshFilters() {
        Task {
            await WebShieldLogger.shared.log("🕒 Refresh process started")

            // Initial setup
            await WebShieldLogger.shared.log("🧹 Clearing previous errors")
            refreshErrorViewModel.clearErrors()

            await WebShieldLogger.shared.logRefreshStart()
            isUpdating = true
            progress = 0
            currentList = 0

            var refreshErrors: [RefreshError] = []

            defer {
                isUpdating = false
                progress = 0
                currentList = 0
                totalLists = 0
                // Determine and set the final refresh state
                // Show error view only if errors occurred
                if !refreshErrors.isEmpty {
                    refreshErrors.forEach { error in
                        refreshErrorViewModel.addError(error)
                    }

                    refreshErrorViewModel.showErrorView = !refreshErrors.isEmpty
                }

            }

            // 1. Fetch all enabled filter lists
            let fetchDescriptor = FetchDescriptor<FilterList>(
                predicate: #Predicate { $0.isEnabled == true }
            )
            await WebShieldLogger.shared.log("🔍 Fetching enabled filter lists")
            guard let enabledLists = try? modelContext.fetch(fetchDescriptor)
            else {
                await WebShieldLogger.shared.log(
                    "❌ Failed to fetch enabled filter lists"
                )
                return
            }

            totalLists = enabledLists.count

            // 2. If no filters at all, handle empty across every category
            if totalLists == 0 {
                await WebShieldLogger.shared.log(
                    "No filters are enabled; writing empty blocklist for each category."
                )
                await writeEmptyBlockersForAllCategories()

                // Reload all content blockers
                for category in FilterListCategory.allCases
                where category != .all && category != .enabled {
                    try await contentBlockerState.reloadContentBlocker(
                        for: category
                    )
                }

                await WebShieldLogger.shared.log(
                    "📋 Found \(totalLists) enabled lists"
                )

                // Persist changes to SwiftData
                await WebShieldLogger.shared.log("Saving Model")
                try modelContext.save()

                AppSettings.shared.hasPerformedInitialRefresh = true
                AppSettings.shared.lastRefreshedEnabledFilters =
                    filterLists
                    .filter { $0.isEnabled }
                    .map { $0.id }
                    .reduce(into: Set<String>()) { $0.insert($1) }

                return
            }

            // 3. Process each filter list and collect results by category
            var resultsByCategory:
                [FilterListCategory: [ProcessedConversionResult]] = [:]
            for (index, filterList) in enabledLists.enumerated() {
                await WebShieldLogger.shared.log(
                    """
                    🛠 Processing list \(index + 1)/\(totalLists):
                    - Name: \(filterList.name)
                    - Category: \(filterList.category?.rawValue ?? "Unknown")
                    """
                )
                do {
                    // Use MainActor.run to access main-actor isolated properties
                    let (result, category) =
                        try await filterListProcessor.processFilterList(
                            filterList
                        )

                    resultsByCategory[category, default: []].append(result)

                    // Update progress
                    currentList = index + 1
                    progress = Double(currentList) / Double(totalLists)
                } catch {
                    await WebShieldLogger.shared.log(
                        "Failed to process \(filterList.name): \(error.localizedDescription)"
                    )
                    // Decide whether to return immediately or continue processing the rest
                    // Add error to the ViewModel
                    let refreshError = RefreshError.localizedError(
                        for: error,
                        in: filterList.name
                    )
                    refreshErrors.append(refreshError)

                }
            }

            // 4. Aggregate all results into a single list
            var combinedResults:
                [(ProcessedConversionResult, FilterListCategory)] = []
            for (category, results) in resultsByCategory {
                combinedResults.append(
                    contentsOf: results.map { ($0, category) }
                )
            }

            // 5. Write all category JSON files once
            await WebShieldLogger.shared.log(
                "📤 Beginning file write operations"
            )
            do {
                guard let groupURL = GroupContainerURL.groupContainerURL()
                else {
                    await WebShieldLogger.shared
                        .log("❌ Could not find App Group container URL.")
                    return
                }

                // Save all content blocker files at once
                try await filterListProcessor.saveContentBlockerFiles(
                    results: combinedResults,
                    directoryURL: groupURL,
                    groupIdentifier: Identifiers.groupID
                )

                // Reload all content blockers
                for category in FilterListCategory.allCases
                where category != .all {
                    try await contentBlockerState.reloadContentBlocker(
                        for: category
                    )
                }

                // Persist changes to SwiftData
                await WebShieldLogger.shared.log("Saving Model")
                try modelContext.save()

                AppSettings.shared.hasPerformedInitialRefresh = true

                // Reset needsRefresh for all filter lists
                for list in filterLists {
                    list.needsRefresh = false
                }

                AppSettings.shared.hasPerformedInitialRefresh = true  // Mark initial refresh as complete
                AppSettings.shared.lastRefreshedEnabledFilters =
                    filterLists
                    .filter { $0.isEnabled }
                    .map { $0.id }
                    .reduce(into: Set<String>()) { $0.insert($1) }
            } catch {
                await WebShieldLogger.shared.log(
                    "Failed to save content blocker files: \(error)"
                )
            }
        }
    }

    /// Returns a minimal “do-nothing” content-blocker rule as JSON.
    private func minimalRuleJSON() -> String {
        """
        [
          {
            "trigger": {
              "url-filter": ".*"
            },
            "action": {
              "type": "ignore-previous-rules"
            }
          }
        ]
        """
    }

    // MARK: - Helper: Write empty JSON for all categories
    private func writeEmptyBlockersForAllCategories() async {
        do {
            guard let groupURL = GroupContainerURL.groupContainerURL() else {
                return
            }

            // Write minimal rule for each category except .all
            for category in FilterListCategory.allCases where category != .all {
                let fileName = "\(category.rawValue.lowercased()).json"
                let fileURL = groupURL.appendingPathComponent(fileName)

                // Prepare minimal rule
                let minimalRule = [
                    [
                        "trigger": [
                            "url-filter": ".*"
                        ],
                        "action": [
                            "type": "ignore-previous-rules"
                        ],
                    ]
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: minimalRule,
                    options: []
                )
                try data.write(to: fileURL, options: .atomic)
                await WebShieldLogger.shared.log(
                    "Wrote minimal rule to \(fileName)"
                )
            }

            // Overwrite advancedBlocking.txt with empty string
            let advancedBlockingURL = groupURL.appendingPathComponent(
                "advancedBlocking.txt"
            )
            try "".write(
                to: advancedBlockingURL,
                atomically: true,
                encoding: .utf8
            )
            await WebShieldLogger.shared.log(
                "Wrote empty advancedBlocking.txt"
            )

            // Build the filter engine with no rules to ensure it's in a clean state
            do {
                let webExtension = try WebExtension.shared(
                    groupID: Identifiers.groupID
                )
                _ = try webExtension.buildFilterEngine(rules: "")
                await WebShieldLogger.shared.log(
                    "✅ Built filter engine with no rules (clean state)"
                )
            } catch {
                await WebShieldLogger.shared.log(
                    "❌ Failed to build filter engine: \(error)"
                )
            }

        } catch {
            await WebShieldLogger.shared.log(
                "Failed to handle empty filters: \(error)"
            )
        }
    }
    // MARK: - Helper: Write empty JSON for a single category
    private func writeEmptyBlocker(
        for category: FilterListCategory,
        at directoryURL: URL
    ) async throws {
        let emptyResult = ProcessedConversionResult(
            converted: minimalRuleJSON(),
            advancedBlocking: nil,
            convertedCount: 0,
            advancedBlockingCount: 0,
            errorsCount: 0,
        )
        try await filterListProcessor.saveContentBlockerFile(
            result: emptyResult,
            category: category,
            directoryURL: directoryURL
        )
        await WebShieldLogger.shared.log(
            "Wrote empty \(category.rawValue.lowercased()).json"
        )
    }

}

// WebShieldApp/Source/Views/ContentView/FilterListView.swift
import SwiftData
import SwiftUI

struct FilterListView: View {
    var category: FilterListCategory  // Keep this - it now receives .enabled too
    @Query(sort: \FilterList.order, order: .forward) private var filterLists: [FilterList]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText: String = ""

    var body: some View {
        List {
            // Filter lists based on the selected category (or enabled state) AND search text
            let filteredLists = getFilteredLists()

            // Show stats based on the filtered list (e.g., count of enabled, total rules of enabled)
            if !filteredLists.isEmpty {
                // Pass the correctly filtered lists (which are the enabled ones if category == .enabled)
                StatsView(filteredLists: filteredLists)
            }

            // Group the lists. If the category is .enabled, show a single "Enabled" section.
            let groupedLists = getGroupedFilterLists(filteredLists: filteredLists)
            ForEach(groupedLists, id: \.id) { section in
                // Use the existing section view logic
                filterListSectionView(section: section)
            }
        }
        .listStyle(.automatic)
        .searchable(text: $searchText)
        // Update navigation title dynamically based on the selected category/state
        .navigationTitle(category.rawValue)
    }

    // MARK: - Helper Methods

    // Updated filtering logic
    private func getFilteredLists() -> [FilterList] {
        filterLists.filter { filterList in
            // Determine if the list matches the category/state criterion
            let categoryOrStateMatches: Bool
            if category == .enabled {
                // For the .enabled "category", only include lists where isEnabled is true
                categoryOrStateMatches = filterList.isEnabled
            } else {
                // For actual categories, use the original logic (match category or show all)
                categoryOrStateMatches = (category == .all || filterList.category == category)
            }

            // Determine if the list matches the search text (if any)
            let searchMatches: Bool
            if searchText.isEmpty {
                searchMatches = true
            } else {
                let searchTextLowercased = searchText.lowercased()
                let nameMatches = filterList.name.lowercased().contains(searchTextLowercased)
                let descMatches = filterList.desc.lowercased().contains(searchTextLowercased)
                searchMatches = nameMatches || descMatches
            }

            // Return true only if both category/state and search criteria are met
            return categoryOrStateMatches && searchMatches
        }
    }

    // Updated grouping logic
    private func getGroupedFilterLists(filteredLists: [FilterList]) -> [FilterListSection] {
        // If the selected "category" is .enabled, return a single section
        if category == .enabled {
            // Only return a section if there are actually enabled lists found
            if filteredLists.isEmpty {
                return []
            }
            // Create a single section titled "Enabled" containing all the filtered (enabled) lists
            // We sort them by their original order here.
            return [
                FilterListSection(
                    title: FilterListCategory.enabled.rawValue,  // Use "Enabled" as the section title
                    filterLists: filteredLists.sorted { $0.order < $1.order },
                    category: .enabled  // Pass the .enabled category itself
                )
            ]
        }

        // --- Original grouping logic for actual categories ---
        let sortedLists = filteredLists.sorted { $0.order < $1.order }
        var sections: [FilterListCategory: [FilterList]] = [:]

        for list in sortedLists {
            // Group by the list's *actual* category, not the selected one (which might be .all)
            if let listCategory = list.category {
                sections[listCategory, default: []].append(list)
            }
        }

        // Define the display order for actual categories
        let categoryOrder: [FilterListCategory] = [
            .ads, .privacy, .security, .multipurpose, .social,
            .cookies, .annoyances, .regional, .experimental,  // Note: .enabled and .all are not typically grouped this way
        ]

        var orderedSections = categoryOrder.compactMap { catOrder in
            // Use the category from the order definition
            if let lists = sections[catOrder], !lists.isEmpty {
                return FilterListSection(title: catOrder.rawValue, filterLists: lists, category: catOrder)
            }
            return nil
        }

        // Append the "Custom" section at the end if it has lists
        if let customLists = sections[.custom], !customLists.isEmpty {
            orderedSections.append(
                FilterListSection(
                    title: FilterListCategory.custom.rawValue,
                    filterLists: customLists,
                    category: .custom
                )
            )
        }

        return orderedSections
    }

    // No changes needed for filterListSectionView and filterListRowView
    @ViewBuilder
    private func filterListSectionView(section: FilterListSection) -> some View {
        // Use section.title which will be "Enabled" or the category name
        Section(header: Text(section.title).font(.headline).textCase(.none)) {
            ForEach(section.filterLists) { filterList in
                filterListRowView(filterList: filterList)
            }
        }
    }

    @ViewBuilder
    private func filterListRowView(filterList: FilterList) -> some View {
        FilterListRow(filterList: filterList)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                // Keep existing delete logic for custom lists
                if filterList.category == .custom {
                    Button(role: .destructive) {
                        withAnimation {
                            _ = Task<Void, Never> {
                                await deleteFilterList(filterList)
                            }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .padding(.vertical, 4)  // Adjusted padding slightly
    }

    // No changes needed for deleteFilterList
    @MainActor
    private func deleteFilterList(_ filterList: FilterList) async {
        modelContext.delete(filterList)
        do {
            try modelContext.save()
            await WebShieldLogger.shared.log("Deleted custom filter list: \(filterList.name)")
        } catch {
            await WebShieldLogger.shared.log("Failed to delete filter list: \(error)")
        }
    }
}

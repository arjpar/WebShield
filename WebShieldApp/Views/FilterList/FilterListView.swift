import SwiftUI

struct FilterListView: View {
    let category: FilterListCategory
    @EnvironmentObject private var filterListManager: FilterListManager
    @StateObject private var viewModel: FilterListViewModel

    init(category: FilterListCategory) {
        self.category = category
        self._viewModel = StateObject(
            wrappedValue: FilterListViewModel(category: category))
    }

    var body: some View {
        Form {
            if category == .all {
                ForEach(FilterListCategory.allCases.dropFirst(), id: \.self) {
                    category in
                    Section(header: Text(category.rawValue)) {
                        ForEach(groupedFilterLists(category)) { filterList in
                            FilterListToggle(filterList: filterList)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(filterListsForCategory) { filter in
                        FilterListToggle(filterList: filter)
                    }
                }
            }

        }
        .formStyle(.grouped)
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ActionButtons(applyChanges: filterListManager.applyChanges)
            }
        }
    }
    private var filterListsForCategory: [FilterList] {
        if category == .all {
            return filterListManager.filterLists
        } else {
            return filterListManager.filterLists.filter {
                $0.category == category
            }
        }
    }

    private func groupedFilterLists(_ category: FilterListCategory) -> [FilterList] {
        return filterListManager.filterLists.filter {
            $0.category == category
        }
    }
}

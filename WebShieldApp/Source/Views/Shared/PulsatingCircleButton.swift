import Foundation
import SwiftData
import SwiftUI

struct PulsatingCircleButton: View {

    enum ButtonState {
        case upToDate
        case needsUpdate
        case notEnabled
    }

    enum FilterState {
        case needsDownload  // Red
        case needsUpdate  // Orange
        case downloaded  // Green
    }

    @State private var isPulsating = false
    @Query(sort: \FilterList.order, order: .forward) private var filterLists: [FilterList]

    var body: some View {
        VStack {
            // Pulsating Circle
            ZStack {
                Circle()
                    .fill(colorForState(currentFilterState()))
                    .frame(width: 4, height: 4)
                    .scaleEffect(isPulsating ? 1.2 : 1.0)
                    .animation(
                        .easeInOut(duration: 1)
                            .repeatForever(autoreverses: true),
                        value: isPulsating
                    )
                    .onAppear {
                        isPulsating = true
                    }

                Circle()
                    .stroke(
                        colorForState(currentFilterState()).opacity(0.6),
                        lineWidth: 8
                    )
                    .frame(width: 2, height: 2)
                    .scaleEffect(isPulsating ? 1.4 : 1.0)
                    .opacity(0.5)
                    .animation(
                        .easeInOut(duration: 1)
                            .repeatForever(autoreverses: true),
                        value: isPulsating
                    )
                    .onAppear {
                        isPulsating = true
                    }
            }
        }
    }

    // MARK: - Helper Functions

    private func colorForState(_ state: FilterState) -> Color {
        switch state {
        case .needsDownload:
            return .red
        case .needsUpdate:
            return .orange
        case .downloaded:
            return .green
        }
    }

    private func currentFilterState() -> FilterState {
        // Determine the state based on the filter lists
        let oneToggledNotDownloaded = filterLists.contains { $0.isEnabled && !$0.downloaded }
        let oneDownloadedNotToggled = filterLists.contains { !$0.isEnabled && $0.downloaded }
        let allDownloaded = filterLists.allSatisfy { $0.downloaded }
        let noneDownloaded = filterLists.allSatisfy { !$0.downloaded }

        if noneDownloaded {
            return .needsDownload  // Red
        } else if oneToggledNotDownloaded || oneDownloadedNotToggled {
            return .needsUpdate  // Orange
        } else if allDownloaded {
            return .downloaded  // Green
        } else {
            return .downloaded  // Default to green
        }

        // TODO
        //        let hasPerformedRefresh = AppSettings.shared.hasPerformedInitialRefresh
        //        let lastRefreshedEnabledFilters = AppSettings.shared.lastRefreshedEnabledFilters
        //        let currentEnabledFilters =
        //            filterLists
        //            .filter { $0.isEnabled }
        //            .map { $0.id }
        //            .reduce(into: Set<String>()) { $0.insert($1) }
        //        let anyListDownloaded = filterLists.contains(where: { $0.downloaded })
        //        let anyListEnabled = filterLists.contains(where: { $0.isEnabled })
        //        let anyEnabledListNeedsDownload = filterLists.contains(where: { $0.isEnabled && !$0.downloaded })
        //        let anyEnabledListNeedsRefresh = filterLists.contains(where: { $0.isEnabled && $0.needsRefresh })
        //
        //        // 1. RED: If no lists are downloaded, none are enabled, OR an initial refresh has never happened
        //        if !anyListDownloaded || !anyListEnabled || !hasPerformedRefresh {
        //            return .needsDownload
        //        }
        //
        //        // 2. ORANGE: Needs Update if:
        //        //    - Any enabled list needs downloading OR
        //        //    - Any enabled list needs a refresh OR
        //        //    - The set of currently enabled filters is different from the last refreshed set
        //        if anyEnabledListNeedsDownload || anyEnabledListNeedsRefresh
        //            || currentEnabledFilters != lastRefreshedEnabledFilters
        //        {
        //            return .needsUpdate
        //        }
        //
        //        // 3. GREEN: If all enabled lists are downloaded, none need a refresh, and the enabled filter configuration hasn't changed since the last refresh.
        //        return .downloaded
    }
}

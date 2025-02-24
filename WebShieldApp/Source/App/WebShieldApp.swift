import SwiftData
import SwiftUI

@main
struct WebShieldApp: App {
    @StateObject private var dataManager = DataManager()
    @StateObject private var refreshErrorViewModel = RefreshErrorViewModel()
    @StateObject private var contentBlockerState: ContentBlockerState
    @StateObject private var advancedExtensionState = WebExtensionState()

    init() {

        let refreshErrorViewModel = RefreshErrorViewModel()
        _refreshErrorViewModel = StateObject(wrappedValue: refreshErrorViewModel)
        _contentBlockerState = StateObject(
            wrappedValue: ContentBlockerState(refreshErrorViewModel: refreshErrorViewModel))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataManager)
                .environmentObject(contentBlockerState)
                .environmentObject(advancedExtensionState)
                .environmentObject(refreshErrorViewModel)
                .modelContainer(dataManager.container)
                .onAppear {
                    Task {
                        await dataManager.seedDataIfNeeded()
                    }
                }
        }
    }

}

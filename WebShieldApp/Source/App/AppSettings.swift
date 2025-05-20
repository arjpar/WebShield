import Foundation

@MainActor
final class AppSettings {
    static let shared = AppSettings()  // Singleton instance

    private init() {}  // Private initializer to enforce singleton

    private let initialRefreshKey = "hasPerformedInitialRefresh"
    @Published var lastRefreshedEnabledFilters: Set<String> = []  // Store identifiers of enabled filters

    @Published var hasPerformedInitialRefresh: Bool = false

    //    var hasPerformedInitialRefresh: Bool {
    //        get {
    //            UserDefaults.standard.bool(forKey: initialRefreshKey)
    //        }
    //        set {
    //            UserDefaults.standard.set(newValue, forKey: initialRefreshKey)
    //        }
    //    }

    // ... other settings properties ...
}

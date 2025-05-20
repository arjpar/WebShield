import SwiftUI

@MainActor
final class ExtensionCheckViewModel: ObservableObject {
    // Dependencies
    private let contentBlockerState: ContentBlockerState
    private let advancedExtensionState: WebExtensionState
    // Possibly another actor for advanced extension checks

    // Published state for UI
    @Published var missingExtensions: [String] = []
    @Published var showEnablePrompt = false

    init(contentBlockerState: ContentBlockerState, advancedExtensionState: WebExtensionState) {
        self.contentBlockerState = contentBlockerState
        self.advancedExtensionState = advancedExtensionState
    }

    func checkExtensions() async {
        missingExtensions.removeAll()
        showEnablePrompt = false

        // Check all content blockers
        for category in FilterListCategory.allCases where category != .all && category != .enabled {
            let isEnabled = await contentBlockerState.isContentBlockerEnabled(for: category)
            await WebShieldLogger.shared.log("Content Blocker for \(category.rawValue) is enabled: \(isEnabled)")
            if !isEnabled {
                missingExtensions.append("WebShield \(category.rawValue)")
            }
        }

        // Check advanced extension
        let advancedEnabled = await advancedExtensionState.isAdvancedExtensionEnabled()
        await WebShieldLogger.shared.log("Advanced (Web)Extension is enabled: \(advancedEnabled)")
        if !advancedEnabled {
            missingExtensions.append("WebShield Advanced")
        }

        // Show prompt only if something’s disabled
        showEnablePrompt = !missingExtensions.isEmpty
    }
}

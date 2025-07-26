import SafariServices

@MainActor
final class WebExtensionState: ObservableObject {
    private let advancedExtensionIdentifier = "dev.arjuna.WebShield.Advanced"

    func isAdvancedExtensionEnabled() async -> Bool {
        #if os(macOS)
        do {
            return try await SFSafariExtensionManager.stateOfSafariExtension(
                withIdentifier: advancedExtensionIdentifier
            ).isEnabled
        } catch {
            return false
        }
        #elseif os(iOS) || os(visionOS)
        return true
        #endif
    }
}

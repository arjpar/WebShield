//
//  GroupIdentifier.swift
//  safari-blocker
//
//  Created by Andrey Meshkov on 01/02/2025.
//

/// GroupIdentifier provides access to the app group identifier used for sharing
/// data between the main app and its extensions.
///
/// This class implements the singleton pattern to ensure consistent access to
/// the app group identifier throughout the application. The group identifier is
/// used to access the shared container where content blocker rules are stored.
public final class GroupIdentifier: Sendable {
    /// Shared singleton instance of GroupIdentifier.
    public static let shared = GroupIdentifier()

    /// The app group identifier string used to access the shared container.
    public let value: String

    /// Initializes a new instance of the GroupIdentifier class.
    private init() {
        // Derive the app group identifier from the bundle identifier
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            fatalError("Unable to get bundle identifier")
        }

        // Extract the base bundle identifier (remove extension-specific suffixes)
        // e.g., "dev.adguard.safari-blocker-mac.TEAM.content-blocker" -> "dev.adguard.safari-blocker-mac.TEAM"
        let baseIdentifier: String
        let suffixes = [
            ".contentblocker-1",
            ".contentblocker-2",
            ".contentblocker-3",
            ".contentblocker-4",
            ".contentblocker-5",
            ".contentblocker-6",
            ".contentblocker-7",
            ".contentblocker-8",
            ".contentblocker-9",
        ]

        if let suffix = suffixes.first(where: { bundleIdentifier.hasSuffix($0) }
        ) {
            baseIdentifier = String(bundleIdentifier.dropLast(suffix.count))
        } else {
            // Fallback: if it contains "WebShield", assume the base is up to "WebShield"
            if let range = bundleIdentifier.range(of: "webshield") {
                let endIndex = range.upperBound
                baseIdentifier = String(bundleIdentifier[..<endIndex])
            } else {
                baseIdentifier = bundleIdentifier
            }
        }

        // Prepend "group." to form the app group identifier
        self.value = "group." + baseIdentifier
    }
}

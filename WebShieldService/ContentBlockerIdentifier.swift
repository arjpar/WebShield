//
//  ContentBlockerIdentifier.swift
//  WebShield
//
//  Created by Andrey Meshkov on 13/10/2025.
//

import Foundation

/// Content blocker identifiers matching the extension bundle ID suffixes (1-9)
public enum ContentBlockerCategory: Int, CaseIterable, Sendable {
    case blocker1 = 1
    case blocker2 = 2
    case blocker3 = 3
    case blocker4 = 4
    case blocker5 = 5
    case blocker6 = 6
    case blocker7 = 7
    case blocker8 = 8
    case blocker9 = 9

    /// The subfolder name for content blocker rules in the app group container
    public static let rulesSubfolder = "BlockListRules"

    /// The bundle identifier suffix for this content blocker extension
    public var bundleSuffix: String {
        ".contentblocker-\(rawValue)"
    }

    /// The filename for storing rules (without subfolder)
    public var rulesFilename: String {
        "arjun.webshield.contentblocker-\(rawValue).json"
    }

    /// The full relative path for rules file (including subfolder)
    public var rulesPath: String {
        "\(Self.rulesSubfolder)/\(rulesFilename)"
    }
}

/// Shared subfolder names used inside the app group container.
public enum AppGroupSubfolder {
    /// Stores compiled Safari content blocker JSON files.
    public static let blockListRules = ContentBlockerCategory.rulesSubfolder
    /// Stores downloaded raw filter list text files.
    public static let filterLists = "FilterLists"
    /// Stores persisted log files.
    public static let logs = "Logs"
}

/// ContentBlockerIdentifier provides utilities for generating content blocker
/// extension identifiers for each category.
///
/// This enum provides methods to get the correct bundle identifier for any
/// content blocker category, supporting the multi-category architecture.
public enum ContentBlockerIdentifier {
    /// Returns the base app bundle identifier (without any extension suffix)
    public static var baseIdentifier: String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            fatalError("Unable to get bundle identifier")
        }

        // Strip any existing content blocker suffix if running from an extension
        var base = bundleIdentifier
        for category in ContentBlockerCategory.allCases {
            if base.hasSuffix(category.bundleSuffix) {
                base = String(base.dropLast(category.bundleSuffix.count))
                break
            }
        }

        // Strip other extension suffixes (Safari Web Extension, Service)
        let extensionSuffixes = [".advanced", ".service"]
        for suffix in extensionSuffixes {
            if base.hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
                break
            }
        }

        return base
    }

    /// Returns the full content blocker identifier for a given category
    /// - Parameter category: The content blocker category
    /// - Returns: The full bundle identifier for the content blocker extension
    public static func identifier(for category: ContentBlockerCategory)
        -> String
    {
        baseIdentifier + category.bundleSuffix
    }

    /// Returns all content blocker identifiers for all categories
    public static var allIdentifiers: [String] {
        ContentBlockerCategory.allCases.map { identifier(for: $0) }
    }

    // MARK: - Legacy Support

    /// Legacy shared instance for backwards compatibility
    /// - Note: Prefer using `identifier(for:)` for new code
    @available(*, deprecated, message: "Use identifier(for:) instead")
    public static let shared = LegacyContentBlockerIdentifier()
}

/// Legacy wrapper for backwards compatibility with code expecting a singleton
@available(
    *,
    deprecated,
    message: "Use ContentBlockerIdentifier.identifier(for:) instead"
)
public final class LegacyContentBlockerIdentifier: Sendable {
    /// The content blocker identifier for blocker1 (legacy default)
    public let value: String

    init() {
        self.value = ContentBlockerIdentifier.identifier(for: .blocker1)
    }
}

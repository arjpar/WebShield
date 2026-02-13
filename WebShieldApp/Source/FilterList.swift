//
//  FilterList.swift
//  WebShield
//
//  Created by Arjun on 2026-02-10.
//

import Foundation
import WebShieldService

private enum BuiltInFilterIDStore {
    private static let defaultsKey = "builtInFilterIDMap"
    private static let lock = NSLock()

    private static var userDefaults: UserDefaults {
        UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
    }

    static func persistentID(for key: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var map = loadMap()

        if let existingID = map[key], UUID(uuidString: existingID) != nil {
            return existingID
        }

        let generatedID = UUID().uuidString.lowercased()
        map[key] = generatedID
        userDefaults.set(map, forKey: defaultsKey)
        return generatedID
    }

    private static func loadMap() -> [String: String] {
        guard
            let storedMap = userDefaults.dictionary(forKey: defaultsKey)
                as? [String: String]
        else {
            return [:]
        }

        var validatedMap: [String: String] = [:]
        validatedMap.reserveCapacity(storedMap.count)

        for (key, value) in storedMap {
            guard UUID(uuidString: value) != nil else { continue }
            validatedMap[key] = value.lowercased()
        }

        if validatedMap.count != storedMap.count {
            userDefaults.set(validatedMap, forKey: defaultsKey)
        }

        return validatedMap
    }
}

struct FilterList: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    var version: String
    var ruleCount: Int? = -1
    let category: FilterCategory
    let downloadURL: URL?
    let homepageURL: URL?
    let informationURL: URL?
    var isEnabled: Bool
    var isPending: Bool = false
    var isDownloading: Bool = false
    var lastError: String?
    var lastUpdated: Date?
    var languages: [String] = []
    var developer: Bool = false

    init(
        id: String? = nil,
        name: String,
        description: String,
        version: String,
        ruleCount: Int? = -1,
        category: FilterCategory,
        downloadURL: URL?,
        homepageURL: URL? = nil,
        informationURL: URL? = nil,
        isEnabled: Bool,
        isPending: Bool = false,
        isDownloading: Bool = false,
        lastError: String? = nil,
        lastUpdated: Date? = nil,
        languages: [String] = ["en"],
        developer: Bool = false,
    ) {
        if let id {
            self.id = id
        } else {
            let stableKey = Self.builtInStableKey(
                name: name,
                category: category,
                downloadURL: downloadURL
            )
            self.id = BuiltInFilterIDStore.persistentID(for: stableKey)
        }
        self.name = name
        self.description = description
        self.version = version
        self.ruleCount = ruleCount
        self.category = category
        self.downloadURL = downloadURL
        self.homepageURL = homepageURL
        self.informationURL = informationURL
        self.isEnabled = isEnabled
        self.isPending = isPending
        self.isDownloading = isDownloading
        self.lastError = lastError
        self.lastUpdated = lastUpdated
        self.languages = languages
        self.developer = developer
    }

    private static func builtInStableKey(
        name: String,
        category: FilterCategory,
        downloadURL: URL?
    ) -> String {
        let normalizedCategory = category.rawValue.lowercased()

        if let downloadURL {
            return
                "category=\(normalizedCategory)|url=\(downloadURL.absoluteString.lowercased())"
        }

        let normalizedName =
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "category=\(normalizedCategory)|name=\(normalizedName)"
    }

    var ruleCountFormatted: String {
        guard ruleCount ?? -1 >= 0 else { return "—" }
        return Formatters.ruleCount.string(
            from: NSNumber(value: ruleCount ?? -1)
        )
            ?? "\(ruleCount ?? -1)"
    }

    var isCustomFilter: Bool {
        id.hasPrefix("custom-")
    }

    /// Returns true if this is an inline user list (created via paste or file import)
    var isInlineUserList: Bool {
        guard let url = downloadURL else { return false }
        return url.scheme?.lowercased() == "webshield"
            && url.host?.lowercased() == "userlist"
    }
}

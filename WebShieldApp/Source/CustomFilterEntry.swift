//
//  CustomFilterEntry.swift
//  WebShield
//
//  Created by Arjun on 2026-02-10.
//

import Foundation

/// Persisted definition of a user-added custom filter
struct CustomFilterEntry: Codable, Identifiable {
    let id: String
    var name: String
    var downloadURL: URL
    var isEnabled: Bool
    var dateAdded: Date

    init(
        id: String = "custom-\(UUID().uuidString)",
        name: String,
        downloadURL: URL,
        isEnabled: Bool = true,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.downloadURL = downloadURL
        self.isEnabled = isEnabled
        self.dateAdded = dateAdded
    }
}

// WebShieldApp/Source/Models/FilterListCategory.swift
import SwiftUI

// Add Codable conformance
enum FilterListCategory: String, CaseIterable, Identifiable, Codable {
    case enabled = "Enabled"
    case all = "All"
    case ads = "Ads"
    case privacy = "Privacy"
    case security = "Security"
    case multipurpose = "Multipurpose"
    case cookies = "Cookies"
    case social = "Social"
    case annoyances = "Annoyances"
    case regional = "Regional"
    case experimental = "Experimental"
    case custom = "Custom"

    var id: String { self.rawValue }

    var systemImage: String {
        switch self {
        case .enabled: return "checkmark.circle.fill"
        case .all: return "square.grid.2x2"
        case .ads: return "megaphone"
        case .privacy: return "hand.raised"
        case .security: return "lock"
        case .multipurpose: return "square.stack.3d.down.right"
        case .cookies: return "circle.dotted.circle"
        case .social: return "bubble.left.and.bubble.right"
        case .annoyances: return "exclamationmark.triangle"
        case .regional: return "globe"
        case .experimental: return "flask"
        case .custom: return "slider.horizontal.3"
        }
    }
}

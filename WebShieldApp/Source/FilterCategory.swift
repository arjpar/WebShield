//
//  FilterCategory.swift
//  WebShield
//
//  Created by Arjun on 2026-02-10.
//

import Foundation
import SwiftUI
import WebShieldService

enum FilterCategory: String, CaseIterable, Identifiable {
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

    static let displayOrder: [FilterCategory] = [
        .ads,
        .privacy,
        .security,
        .multipurpose,
        .cookies,
        .social,
        .annoyances,
        .regional,
        .experimental,
        .custom,
    ]

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ads: return "xmark.shield"
        case .annoyances: return "bell.slash.fill"
        case .cookies: return "hand.raised.fill"
        case .custom: return "slider.horizontal.3"
        case .experimental: return "flask.fill"
        case .multipurpose: return "square.stack.3d.up.fill"
        case .privacy: return "eye.slash.fill"
        case .regional: return "globe"
        case .security: return "lock.shield.fill"
        case .social: return "bubble.left.and.bubble.right.fill"
        }
    }

    var color: Color {
        switch self {
        case .ads: return .red
        case .annoyances: return .orange
        case .cookies: return .brown
        case .custom: return .gray
        case .experimental: return .pink
        case .multipurpose: return .indigo
        case .privacy: return .blue
        case .regional: return .teal
        case .security: return .green
        case .social: return .purple
        }
    }

    /// Maps to the WebShield ContentBlockerCategory (blocker number)
    var serviceCategory: ContentBlockerCategory {
        switch self {
        case .ads: return .blocker1
        case .privacy: return .blocker2
        case .security: return .blocker3
        case .multipurpose: return .blocker4
        case .cookies: return .blocker5
        case .social: return .blocker6
        case .annoyances: return .blocker7
        case .regional: return .blocker8
        case .experimental: return .blocker9
        case .custom: return .blocker9
        }
    }

    /// The JSON file path used in the shared app group container
    var rulesFilename: String {
        serviceCategory.rulesPath
    }

    /// Full content blocker identifier for Safari
    var contentBlockerIdentifier: String {
        ContentBlockerIdentifier.identifier(for: serviceCategory)
    }
}

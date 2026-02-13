//
//  AppTab.swift
//  WebShield
//
//  Created by Arjun on 2026-02-09.
//

import Foundation
import SafariServices
import SwiftUI
import UniformTypeIdentifiers
import WebShieldService

enum AppTab: String, CaseIterable, Identifiable {
    case filters = "Filters"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .filters: return "line.3.horizontal.decrease.circle"
        case .settings: return "gearshape"
        }
    }
}

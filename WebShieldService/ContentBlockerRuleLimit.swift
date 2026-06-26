//
//  ContentBlockerRuleLimit.swift
//  WebShieldService
//

import Foundation

public enum ContentBlockerRuleLimit {
    public static let macOS = 150_000
    public static let iOS = 50_000
    public static let visionOS = 50_000

    public static var currentPlatformLimit: Int {
        #if os(macOS)
            macOS
        #elseif os(visionOS)
            visionOS
        #else
            iOS
        #endif
    }

    public static var currentPlatformWarningThreshold: Int {
        Int(Double(currentPlatformLimit) * 0.8)
    }
}

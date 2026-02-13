//
//  Constants.swift
//  WebShield
//
//  Created by Arjun on 2026-02-10.
//

// MARK: - Constants

public enum Constants {
    /// Number of header lines to scan when parsing filter list metadata
    static let headerLinesToScan = 50
    /// Delay after refresh completes to show completion state
    static let refreshCompletionDelay: Duration = .milliseconds(500)
    /// Minimum progress shown during refresh preparation
    static let refreshPreparationProgress: Double = 0.02
    /// Progress range used for downloads
    static let refreshDownloadProgressRange: Double = 0.68
    /// Progress range used for category conversion/reload work
    static let refreshCategoryProgressRange: Double = 0.20
    /// Progress shown when building the advanced engine starts
    static let refreshBuildProgress: Double = 0.94
    /// Progress shown after finishing the engine rebuild
    static let refreshFinalizingProgress: Double = 0.98
}

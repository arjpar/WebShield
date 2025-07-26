@preconcurrency import SafariServices
import SwiftUI

@MainActor
final class ContentBlockerState: ObservableObject {
  var refreshErrorViewModel: RefreshErrorViewModel
  private let maxRetryAttempts = 5
  
  init(refreshErrorViewModel: RefreshErrorViewModel) {
    self.refreshErrorViewModel = refreshErrorViewModel
  }

  // Reload content blocker for a specific category
  func reloadContentBlocker(for category: FilterListCategory) async throws {
    await WebShieldLogger.shared.log("🔄 Starting reload for \(category.rawValue)")
    // Skip reloading for the "all" and "enabled" categories
    guard category != .all && category != .enabled else { return }

    let identifier = "dev.arjuna.WebShield.DeclarativeBlockList-\(category.rawValue)"
    do {
      try await reloadContentBlockerWithRetry(identifier: identifier, category: category, attemptCount: 1)
    } catch {
      await handleReloadError(error, for: category)
    }
  }
  
  // Helper method to reload content blocker with retry logic
  private func reloadContentBlockerWithRetry(identifier: String, category: FilterListCategory, attemptCount: Int) async throws {
    do {
      try await SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier)
      await WebShieldLogger.shared.log(
        "Content blocker reloaded successfully for category: \(category.rawValue)")
    } catch {
      if attemptCount < maxRetryAttempts {
        await WebShieldLogger.shared.log(
          "Reload attempt \(attemptCount) failed for \(category.rawValue). Retrying... (\(attemptCount)/\(maxRetryAttempts))")
        
        // Add a small delay before retrying (increasing with each attempt)
        try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(attemptCount) * 1_000_000_000))
        
        // Recursive call for next attempt
        try await reloadContentBlockerWithRetry(
          identifier: identifier, 
          category: category, 
          attemptCount: attemptCount + 1
        )
      } else {
        await WebShieldLogger.shared.log(
          "All \(maxRetryAttempts) reload attempts failed for \(category.rawValue)")
        throw error
      }
    }
  }

  // Add a new method to report errors
  private func reportError(title: String, message: String) {
    let error = RefreshError(title: title, message: message, timestamp: Date())
    refreshErrorViewModel.addError(error)
  }

  // Handle errors, now with category
  private func handleReloadError(_ error: Error, for category: FilterListCategory) async {
    let nsError = error as NSError
    await WebShieldLogger.shared.log(
      "ERROR: Failed to reload content blocker for category: \(category.rawValue)")
    await WebShieldLogger.shared.log("Error description: \(nsError.localizedDescription)")
    await WebShieldLogger.shared.log("Error domain: \(nsError.domain)")
    await WebShieldLogger.shared.log("Error code: \(nsError.code)")

    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
      await WebShieldLogger.shared.log("Underlying error: \(underlyingError)")
    }

    await WebShieldLogger.shared.log("User Info:")
    for (key, value) in nsError.userInfo {
      await WebShieldLogger.shared.log("  \(key): \(value)")
    }

    if nsError.domain == "SFErrorDomain" {
      await handleSFErrorDomain(code: nsError.code, for: category)
    } else {
      // Handle other error domains if needed
      reportError(
        title: "Error Reloading \(category.rawValue)",
        message: "Error \(nsError.code): \(nsError.localizedDescription)")
    }
  }

  // MARK: - NEW: Check if a content blocker is enabled for a category
  func isContentBlockerEnabled(for category: FilterListCategory) async -> Bool {
    // If category is .all, we might treat it as "not applicable"
    guard category != .all else { return true }

    let identifier = "dev.arjuna.WebShield.DeclarativeBlockList-\(category.rawValue)"

    // Use a continuation to convert completion-handler to async/await
    do {
      return try await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: identifier)
        .isEnabled
    } catch {
      return false
    }
  }

  // Handle SFErrorDomain errors, now with category
  private func handleSFErrorDomain(code: Int, for category: FilterListCategory) async {
    let identifier = "dev.arjuna.WebShield.DeclarativeBlockList-\(category.rawValue)"
    let title = "Content Blocker Error (\(category.rawValue))"
    let message: String

    switch code {
    case 1:
      message = "Content Blocker not found. Check the identifier: \(identifier)"
      await WebShieldLogger.shared.log(
        "SFErrorDomain error 1: Content Blocker not found or not owned by you."
      )
      await WebShieldLogger.shared.log("Bundle Identifier: \(identifier)")
      await WebShieldLogger.shared.log(
        "Please check JSON validity and file size (max 6MB, 150,000 rules)."
      )
    case 2:
      message = "No attachment found in NSExtensionItem."
      await WebShieldLogger.shared.log("SFErrorDomain error 2: NSExtensionItem missing attachment.")
    case 3:
      message = "Error loading content blocker extension."
      await WebShieldLogger.shared.log(
        "SFErrorDomain error 3: Error loading content blocker extension."
      )
    default:
      message = "Unknown SFErrorDomain error code: \(code)"
      await WebShieldLogger.shared.log("Unknown SFErrorDomain error code: \(code)")
    }

    reportError(title: title, message: message)
  }
}

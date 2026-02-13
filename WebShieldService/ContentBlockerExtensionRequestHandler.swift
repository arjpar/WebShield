//
//  ContentBlockerExtensionRequestHandler.swift
//  safari-blocker
//
//  Created by Andrey Meshkov on 10/12/2024.
//

import Foundation
import UniformTypeIdentifiers

/// Implements Safari content blocker extension logic.
/// This handler is responsible for loading content blocking rules from the
/// shared container and providing them to Safari extensions.
///
/// The rules are loaded from a shared location that is accessible by both the main app
/// and the content blocker extension. If no custom rules are found, it falls back to
/// the default blocker list included in the extension bundle.
public enum ContentBlockerExtensionRequestHandler {
    private static let logger = WebShieldLogger.shared
    private static let logCategory = "ContentBlocker"

    /// Handles content blocking extension request for rules.
    ///
    /// This method loads the content blocker rules JSON file from the shared container
    /// and attaches it to the extension context to be used by Safari.
    ///
    /// - Parameters:
    ///   - context: The extension context that initiated the request.
    ///   - groupIdentifier: The app group identifier used to access the shared container.
    public static func handleRequest(with context: NSExtensionContext, groupIdentifier: String, rulesFilenameInAppGroup: String) {
        let startTime = DispatchTime.now()

        logger.info(
            "Loading content blocker: \(rulesFilenameInAppGroup)",
            category: logCategory
        )

        // Get the shared container URL using the provided group identifier
        guard
            let appGroupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else {
            logger.error(
                "Failed to access App Group container: \(groupIdentifier)",
                category: logCategory
            )
            context.cancelRequest(
                withError: createError(code: 1001, message: "Failed to access App Group container.")
            )
            return
        }

        // Construct the path to the shared blocker list file
        let sharedFileURL = appGroupURL.appendingPathComponent(rulesFilenameInAppGroup)

        // Determine which blocker list file to use
        var blockerListFileURL = sharedFileURL
        var isUsingDefault = false

        if !FileManager.default.fileExists(atPath: sharedFileURL.path) {
            logger.info(
                "Custom blocker list not found at \(rulesFilenameInAppGroup), using default",
                category: logCategory
            )

            // Fall back to the default blocker list included in the bundle
            if let defaultURL = Bundle.main.url(forResource: "blockerList", withExtension: "json") {
                blockerListFileURL = defaultURL
                isUsingDefault = true
            } else {
                logger.error(
                    "Default blocker list not found in bundle for \(rulesFilenameInAppGroup), returning empty rules",
                    category: logCategory
                )
                completeWithEmptyRules(
                    context: context,
                    rulesFilename: rulesFilenameInAppGroup,
                    reason: "missing files",
                    startTime: startTime
                )
                return
            }
        }

        // Get file size for logging
        let fileSize: String
        if let attributes = try? FileManager.default.attributesOfItem(atPath: blockerListFileURL.path),
           let size = attributes[.size] as? UInt64
        {
            fileSize = formatBytes(size)
        } else {
            fileSize = "unknown size"
        }

        // Create an attachment with the blocker list file
        guard let attachment = NSItemProvider(contentsOf: blockerListFileURL) else {
            logger.error(
                "Failed to create attachment from \(blockerListFileURL.lastPathComponent), returning empty rules",
                category: logCategory
            )
            completeWithEmptyRules(
                context: context,
                rulesFilename: rulesFilenameInAppGroup,
                reason: "attachment failure",
                startTime: startTime
            )
            return
        }

        // Prepare and complete the extension request with the blocker list
        let item = NSExtensionItem()
        item.attachments = [attachment]

        let sourceDescription = isUsingDefault ? "default bundle" : "app group"

        context.completeRequest(
            returningItems: [item]
        ) { _ in
            let endTime = DispatchTime.now()
            let elapsedMs = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
            let elapsedFormatted = String(format: "%.1f", elapsedMs)

            logger.info(
                "Loaded \(rulesFilenameInAppGroup) (\(fileSize)) from \(sourceDescription) in \(elapsedFormatted) ms",
                category: logCategory
            )
        }
    }

    /// Completes the extension request with empty rules as a graceful fallback.
    ///
    /// This ensures the extension doesn't fail completely when rules can't be loaded,
    /// providing a better user experience than canceling the request with an error.
    ///
    /// - Parameters:
    ///   - context: The extension context to complete.
    ///   - rulesFilename: The original rules filename for logging.
    ///   - reason: A description of why empty rules are being returned.
    ///   - startTime: The start time for elapsed time calculation.
    private static func completeWithEmptyRules(
        context: NSExtensionContext,
        rulesFilename: String,
        reason: String,
        startTime: DispatchTime
    ) {
        let emptyRules = "[]"
        let item = NSExtensionItem()
        item.attachments = [
            NSItemProvider(
                item: emptyRules.data(using: .utf8) as NSData?,
                typeIdentifier: UTType.json.identifier
            )
        ]

        context.completeRequest(returningItems: [item]) { _ in
            let endTime = DispatchTime.now()
            let elapsedMs = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
            let elapsedFormatted = String(format: "%.1f", elapsedMs)

            logger.info(
                "Loaded empty rules for \(rulesFilename) due to \(reason) in \(elapsedFormatted) ms",
                category: logCategory
            )
        }
    }

    /// Creates an NSError with the specified code and message.
    ///
    /// - Parameters:
    ///   - code: The error code.
    ///   - message: The error message.
    /// - Returns: An NSError object with the specified parameters.
    private static func createError(code: Int, message: String) -> NSError {
        return NSError(
            domain: "arjun.webshield",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

//
//  WebExtensionRequestHandler.swift
//  safari-blocker
//
//  Created by Andrey Meshkov on 11/04/2025.
//

internal import FilterEngine
import Foundation
import SafariServices

/// WebExtensionRequestHandler processes requests from Safari Web Extensions and provides
/// content blocking configuration for web pages.
///
/// This handler receives requests from the extension's background page, looks up the
/// appropriate blocking rules for the requested URL, and returns the configuration
/// back to the extension.
public enum WebExtensionRequestHandler {
    private static let logger = WebShieldLogger.shared
    private static let logCategory = "WebExtension"

    /// Processes an extension request and provides content blocking configuration.
    ///
    /// This method extracts the URL from the request, looks up the appropriate blocking
    /// rules using WebExtension, and returns the configuration back to the extension.
    /// It also respects the whitelist - if a domain is whitelisted, no blocking rules
    /// are returned for it.
    ///
    /// - Parameters:
    ///   - context: The extension context containing the request from the extension.
    public static func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem

        var message = getMessage(from: request)

        if message == nil {
            context.completeRequest(returningItems: [])

            return
        }

        // Check message type for whitelist operations
        if let messageType = message?["type"] as? String {
            switch messageType {
            case "checkWhitelist":
                handleCheckWhitelist(message: &message)
            case "toggleWhitelist":
                handleToggleWhitelist(message: &message)
            default:
                // Handle standard content blocking request
                handleContentBlockingRequest(message: &message)
            }
        } else {
            // Handle standard content blocking request (legacy format)
            handleContentBlockingRequest(message: &message)
        }

        if let safeMessage = message {
            let response = createResponse(with: safeMessage)
            context.completeRequest(
                returningItems: [response],
                completionHandler: nil
            )
        } else {
            context.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    /// Handles a checkWhitelist request from the extension.
    ///
    /// - Parameter message: The message dictionary to update with the response.
    private static func handleCheckWhitelist(message: inout [String: Any?]?) {
        let payload = message?["payload"] as? [String: Any] ?? [:]

        // Check for domain in payload first (from background-wrapper.js),
        // then at root level (Safari auto-forwarded from popup)
        let domain = payload["domain"] as? String ?? message?["domain"] as? String

        if let domain = domain {
            let isWhitelisted = WhitelistManager.shared.isDomainWhitelisted(domain)
            logger.info(
                "Checking whitelist status for domain: \(domain) - isWhitelisted: \(isWhitelisted)",
                category: logCategory
            )
            message?["payload"] = [
                "isWhitelisted": isWhitelisted
            ]
        } else {
            message?["payload"] = [
                "isWhitelisted": false
            ]
        }
    }

    /// Handles a toggleWhitelist request from the extension.
    ///
    /// - Parameter message: The message dictionary to update with the response.
    private static func handleToggleWhitelist(message: inout [String: Any?]?) {
        let payload = message?["payload"] as? [String: Any] ?? [:]

        // Check for domain in payload first (from background-wrapper.js),
        // then at root level (Safari auto-forwarded from popup)
        guard let domain = payload["domain"] as? String ?? message?["domain"] as? String else {
            logger.error("toggleWhitelist: No domain found in payload or message root", category: logCategory)
            message?["payload"] = ["success": false]
            return
        }

        // Check for whitelist in payload first, then at root level
        // Note: Safari auto-forwarded messages may use Int (1/0) instead of Bool
        let shouldWhitelist: Bool
        if let whitelistBool = payload["whitelist"] as? Bool {
            shouldWhitelist = whitelistBool
        } else if let whitelistBool = message?["whitelist"] as? Bool {
            shouldWhitelist = whitelistBool
        } else if let whitelistInt = message?["whitelist"] as? Int {
            shouldWhitelist = whitelistInt != 0
        } else {
            shouldWhitelist = false
        }
        let isCurrentlyWhitelisted = WhitelistManager.shared.isDomainWhitelisted(domain)

        logger.info(
            "Toggling whitelist for domain: \(domain) - shouldWhitelist: \(shouldWhitelist), isCurrentlyWhitelisted: \(isCurrentlyWhitelisted)",
            category: logCategory
        )

        // If already in desired state, return success without modifying
        if shouldWhitelist == isCurrentlyWhitelisted {
            logger.info(
                "Domain \(domain) is already in desired whitelist state: \(shouldWhitelist)",
                category: logCategory
            )
            message?["payload"] = ["success": true]
            return
        }

        var success = false
        if shouldWhitelist {
            success = WhitelistManager.shared.addDomain(domain)
        } else {
            success = WhitelistManager.shared.removeDomain(domain)
        }

        // If whitelist changed, update content blockers
        if success {
            updateContentBlockersForWhitelist()
        }

        message?["payload"] = ["success": success]
    }

    /// Updates all content blockers with the new whitelist.
    /// This method dispatches the heavy work asynchronously to avoid blocking
    /// the native message response, which can cause timeout errors.
    private static func updateContentBlockersForWhitelist() {
        // Dispatch content blocker updates to background queue to avoid
        // blocking the native message response. Safari's native messaging
        // can timeout if we wait for all content blockers to reload.
        DispatchQueue.global(qos: .userInitiated).async {
            // Fast update all content blockers with new whitelist rules
            for category in ContentBlockerCategory.allCases {
                _ = ContentBlockerService.fastUpdateWhitelist(
                    groupIdentifier: GroupIdentifier.shared.value,
                    rulesFilename: category.rulesPath
                )

                // Reload the content blocker
                _ = ContentBlockerService.reloadContentBlocker(
                    withIdentifier: ContentBlockerIdentifier.identifier(for: category)
                )
            }

            logger.info("Content blockers updated with new whitelist", category: logCategory)
        }
    }

    /// Handles a standard content blocking configuration request.
    ///
    /// - Parameter message: The message dictionary to update with the response.
    private static func handleContentBlockingRequest(message: inout [String: Any?]?) {
        let payload = message?["payload"] as? [String: Any] ?? [:]

        if let urlString = payload["url"] as? String {
            if let url = URL(string: urlString) {
                // Check if the host is whitelisted
                if let host = url.host,
                    WhitelistManager.shared.isHostWhitelisted(host)
                {
                    logger.info(
                        "Host is whitelisted, skipping advanced rules: \(host)",
                        category: logCategory
                    )
                    // Return empty payload for whitelisted sites
                    message?["payload"] = [
                        "whitelisted": true,
                        "css": [] as [String],
                        "extendedCss": [] as [String],
                        "js": [] as [String],
                        "scriptlets": [] as [[String: Any]],
                    ]
                } else {
                    do {
                        let webExtension = try WebExtension.shared(
                            groupID: GroupIdentifier.shared.value
                        )

                        var topUrl: URL?
                        if let topUrlString = payload["topUrl"] as? String {
                            topUrl = URL(string: topUrlString)
                        }

                        if let configuration = webExtension.lookup(
                            pageUrl: url,
                            topUrl: topUrl
                        ) {
                            message?["payload"] = convertToPayload(configuration)
                        }
                    } catch {
                        logger.error(
                            "Failed to get WebExtension instance: \(error.localizedDescription)",
                            category: logCategory
                        )
                    }
                }
            }
        }
    }

    /// Converts a WebExtension.Configuration object to a dictionary payload.
    ///
    /// - Parameters:
    ///   - configuration: The WebExtension.Configuration object to convert.
    /// - Returns: A dictionary containing CSS, extended CSS, JS, and scriptlets
    ///           that should be applied to the web page.
    private static func convertToPayload(
        _ configuration: WebExtension.Configuration
    ) -> [String: Any] {
        var payload: [String: Any] = [:]
        payload["css"] = configuration.css
        payload["extendedCss"] = configuration.extendedCss
        payload["js"] = configuration.js

        var scriptlets: [[String: Any]] = []
        for scriptlet in configuration.scriptlets {
            var scriptletData: [String: Any] = [:]
            scriptletData["name"] = scriptlet.name
            scriptletData["args"] = scriptlet.args
            scriptlets.append(scriptletData)
        }

        payload["scriptlets"] = scriptlets
        payload["engineTimestamp"] = configuration.engineTimestamp

        return payload
    }

    /// Creates an NSExtensionItem response with the provided JSON payload.
    ///
    /// - Parameters:
    ///   - json: The JSON payload to include in the response.
    /// - Returns: An NSExtensionItem containing the response message.
    private static func createResponse(with json: [String: Any?])
        -> NSExtensionItem
    {
        let response = NSExtensionItem()
        if #available(iOS 15.0, macOS 11.0, *) {
            response.userInfo = [SFExtensionMessageKey: json]
        } else {
            response.userInfo = ["message": json]
        }

        return response
    }

    /// Extracts the message from an extension request.
    ///
    /// This method handles different Safari versions by using the appropriate
    /// keys for accessing the message and profile information.
    ///
    /// - Parameters:
    ///   - request: The NSExtensionItem containing the request from the extension.
    /// - Returns: The message dictionary or nil if no valid message was found.
    private static func getMessage(from request: NSExtensionItem?) -> [String:
        Any?]?
    {
        if request == nil {
            return nil
        }

        let profile: UUID?
        if #available(iOS 17.0, macOS 14.0, *) {
            profile = request?.userInfo?[SFExtensionProfileKey] as? UUID
        } else {
            profile = request?.userInfo?["profile"] as? UUID
        }

        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        logger.info(
            "Received message from browser.runtime.sendNativeMessage: \(String(describing: message)) (profile: \(profile?.uuidString ?? "none"))",
            category: logCategory
        )

        if message is [String: Any?] {
            return message as? [String: Any?]
        }

        return nil
    }
}

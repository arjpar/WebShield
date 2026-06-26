//
//  WebExtensionRequestHandler.swift
//  safari-blocker
//
//  Created by Andrey Meshkov on 11/04/2025.
//

internal import adblock_rust_swift
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

        // Dispatch on message type. Unknown types receive an empty payload —
        // the AdGuard-era "default" branch that handled cosmetic/scriptlet
        // requests has been replaced by explicit cosmeticSetup /
        // cosmeticSelectors types.
        if let messageType = message?["type"] as? String {
            switch messageType {
            case "checkWhitelist":
                handleCheckWhitelist(message: &message)
            case "toggleWhitelist":
                handleToggleWhitelist(message: &message)
            case "cosmeticSetup":
                handleCosmeticSetupRequest(message: &message)
            case "cosmeticSelectors":
                handleCosmeticSelectorsRequest(message: &message)
            default:
                let payloadKeys = (message?["payload"] as? [String: Any])?
                    .keys
                    .sorted()
                    .joined(separator: ",") ?? ""
                logger.warning(
                    "Native bridge: unknown message type=\(messageType) (payload keys: \(payloadKeys.isEmpty ? "none" : payloadKeys))",
                    category: logCategory
                )
                message?["payload"] = [:] as [String: Any]
            }
        } else {
            let rootKeys = message?.keys.sorted().joined(separator: ",") ?? ""
            logger.warning(
                "Native bridge: message has no type field (root keys: \(rootKeys.isEmpty ? "none" : rootKeys))",
                category: logCategory
            )
            message?["payload"] = [:] as [String: Any]
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

            logger.info(
                "Whitelist change applied: \(ContentBlockerCategory.allCases.count) Safari blockers fast-updated and reloaded",
                category: logCategory
            )
        }
    }

    /// Handles a `cosmeticSetup` request: returns the engine's per-URL
    /// cosmetic resources for the page that just loaded its content script.
    ///
    /// Response payload shape (matches what `content_cosmetic.js` expects):
    /// ```
    /// {
    ///   hideSelectors:     [String]
    ///   proceduralActions: [String]   // raw JSON; JS side decodes
    ///   exceptions:        [String]
    ///   scriptletInjections: [[String: Any]]
    ///   injectedScript:    String
    ///   genericHide:       Bool
    ///   engineTimestamp:   Int64
    ///   whitelisted:       Bool      // optional, true when host is whitelisted
    /// }
    /// ```
    private static func handleCosmeticSetupRequest(message: inout [String: Any?]?) {
        let payload = message?["payload"] as? [String: Any] ?? [:]

        guard
            let urlString = payload["url"] as? String,
            let url = URL(string: urlString)
        else {
            message?["payload"] = emptyCosmeticSetupPayload(
                engineTimestamp: 0,
                whitelisted: false
            )
            return
        }

        let host = url.host ?? "(no host)"

        if let actualHost = url.host,
            WhitelistManager.shared.isHostWhitelisted(actualHost)
        {
            logger.info(
                "cosmeticSetup: \(actualHost) is whitelisted — returning empty cosmetic payload",
                category: logCategory
            )
            message?["payload"] = emptyCosmeticSetupPayload(
                engineTimestamp: 0,
                whitelisted: true
            )
            return
        }

        guard
            let snapshot = ContentBlockerService.loadAdvancedBlockingEngine(
                groupIdentifier: GroupIdentifier.shared.value
            )
        else {
            logger.info(
                "cosmeticSetup: adblock-rust engine snapshot not loaded — returning empty payload for \(host)",
                category: logCategory
            )
            message?["payload"] = emptyCosmeticSetupPayload(
                engineTimestamp: 0,
                whitelisted: false
            )
            return
        }

        let isTopFrame = payload["isTopFrame"] as? Bool ?? true
        let resources = snapshot.engine.cosmeticResourceDetails(
            for: url.absoluteString,
            isTopFrame: isTopFrame
        )

        let scriptletSize = resources.injectedScript.utf8.count
        let scriptletDesc = scriptletSize == 0 ? "no" : "\(scriptletSize)B"
        let scriptletInjections = resources.scriptletInjections.map {
            [
                "name": $0.name,
                "args": $0.args,
            ] as [String: Any]
        }
        logger.info(
            "cosmeticSetup ← adblock-rust for \(host): topFrame=\(isTopFrame), hide=\(resources.hideSelectors.count), procedural=\(resources.proceduralActions.count), scriptlet=\(scriptletDesc), scriptletInvocations=\(scriptletInjections.count), genericHide=\(resources.generichide), exceptions=\(resources.exceptions.count)",
            category: logCategory
        )

        message?["payload"] = [
            "hideSelectors": resources.hideSelectors,
            "proceduralActions": resources.proceduralActions,
            "exceptions": resources.exceptions,
            "scriptletInjections": scriptletInjections,
            "injectedScript": resources.injectedScript,
            "genericHide": resources.generichide,
            "engineTimestamp": snapshot.metadata.engineTimestamp,
        ]
    }

    /// Handles a `cosmeticSelectors` request: given a batch of ids/classes
    /// observed in the DOM, returns the class/id-targeted hide selectors the
    /// engine wants to apply.
    ///
    /// Response payload: `{ selectors: [String] }`.
    private static func handleCosmeticSelectorsRequest(message: inout [String: Any?]?) {
        let payload = message?["payload"] as? [String: Any] ?? [:]

        guard
            let urlString = payload["url"] as? String,
            let url = URL(string: urlString)
        else {
            message?["payload"] = ["selectors": [] as [String]]
            return
        }

        if let host = url.host,
            WhitelistManager.shared.isHostWhitelisted(host)
        {
            message?["payload"] = ["selectors": [] as [String]]
            return
        }

        guard
            let snapshot = ContentBlockerService.loadAdvancedBlockingEngine(
                groupIdentifier: GroupIdentifier.shared.value
            )
        else {
            message?["payload"] = ["selectors": [] as [String]]
            return
        }

        let classes = stringArray(from: payload["classes"])
        let ids = stringArray(from: payload["ids"])
        let exceptionsJSON = payload["exceptionsJSON"] as? String ?? "[]"

        let selectors = snapshot.engine.selectorsForCosmeticRules(
            classes: classes,
            ids: ids,
            exceptionsJSON: exceptionsJSON
        )

        logger.debug(
            "cosmeticSelectors ← adblock-rust for \(url.host ?? "(no host)"): \(classes.count) classes + \(ids.count) ids → \(selectors.count) targeted hide rules",
            category: logCategory
        )

        message?["payload"] = ["selectors": selectors]
    }

    private static func emptyCosmeticSetupPayload(
        engineTimestamp: Int64,
        whitelisted: Bool
    ) -> [String: Any] {
        [
            "hideSelectors": [] as [String],
            "proceduralActions": [] as [String],
            "exceptions": [] as [String],
            "scriptletInjections": [] as [[String: Any]],
            "injectedScript": "",
            "genericHide": false,
            "engineTimestamp": engineTimestamp,
            "whitelisted": whitelisted,
        ]
    }

    private static func stringArray(from value: Any?) -> [String] {
        guard let values = value as? [String] else {
            return []
        }
        return Array(Set(values.filter { !$0.isEmpty })).sorted()
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

        let dict = message as? [String: Any?]
        let messageType = (dict?["type"] as? String) ?? "(none)"
        let payloadKeys = (dict?["payload"] as? [String: Any])?
            .keys
            .sorted()
            .joined(separator: ",") ?? ""
        let profileShort = profile?.uuidString.prefix(8).description ?? "none"

        logger.info(
            "Native bridge ← \(messageType) (payload: \(payloadKeys.isEmpty ? "none" : payloadKeys)) profile=\(profileShort)",
            category: logCategory
        )
        logger.debug(
            "Native bridge raw message: \(String(describing: message))",
            category: logCategory
        )

        if message is [String: Any?] {
            return message as? [String: Any?]
        }

        return nil
    }
}

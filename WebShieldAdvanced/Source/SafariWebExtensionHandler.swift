//
//  WebExtensionRequestHandler.swift
//
//  Created by Arjun on 2025-07-10.
//

internal import FilterEngine
import SafariServices
import os.log

/// WebExtensionRequestHandler processes requests from Safari Web Extensions and provides
/// content blocking configuration for web pages.
///
/// This handler receives requests from the extension's background page, looks up the
/// appropriate blocking rules for the requested URL, and returns the configuration
/// back to the extension.
final public class SafariWebExtensionHandler: NSObject,
    NSExtensionRequestHandling
{
    /// Processes an extension request and provides content blocking configuration.
    ///
    /// This method extracts the URL from the request, looks up the appropriate blocking
    /// rules using WebExtension, and returns the configuration back to the extension.
    ///
    /// - Parameters:
    ///   - context: The extension context containing the request from the extension.
    public func beginRequest(with context: NSExtensionContext) {
        print("[WebShield] beginRequest called")
        os_log(.info, "[WebShield] beginRequest called")
        let request = context.inputItems.first as? NSExtensionItem

        var message = getMessage(from: request)
        os_log(
            .info,
            "[WebShield] Extracted message: %{public}@",
            String(describing: message)
        )

        if message == nil {
            os_log(.error, "[WebShield] No message found in request")
            context.completeRequest(returningItems: [])
            return
        }

        let nativeStart = Int64(Date().timeIntervalSince1970 * 1000)

        let payload = message?["payload"] as? [String: Any] ?? [:]
        os_log(
            .info,
            "[WebShield] Payload: %{public}@",
            String(describing: payload)
        )
        if let urlString = payload["url"] as? String {
            if let url = URL(string: urlString) {
                do {
                    os_log(.info, "[WebShield] Creating WebExtension instance")
                    let webExtension = try WebExtension.shared(
                        groupID: "group.dev.arjuna.WebShield"
                    )

                    var topUrl: URL?
                    if let topUrlString = payload["topUrl"] as? String {
                        topUrl = URL(string: topUrlString)
                    }

                    os_log(
                        .info,
                        "[WebShield] Looking up configuration for url: %{public}@, topUrl: %{public}@",
                        url.absoluteString,
                        String(describing: topUrl)
                    )
                    if let configuration = webExtension.lookup(
                        pageUrl: url,
                        topUrl: topUrl
                    ) {
                        os_log(
                            .info,
                            "[WebShield] Lookup returned configuration: %{public}@",
                            String(describing: configuration)
                        )
                        message?["payload"] = convertToPayload(configuration)
                    } else {
                        os_log(
                            .error,
                            "[WebShield] Lookup returned nil for url: %{public}@",
                            url.absoluteString
                        )
                    }
                } catch {
                    os_log(
                        .error,
                        "[WebShield] Failed to get WebExtension instance: %{public}@",
                        error.localizedDescription
                    )
                }
            } else {
                os_log(
                    .error,
                    "[WebShield] Invalid url string: %{public}@",
                    urlString
                )
            }
        } else {
            os_log(
                .error,
                "[WebShield] No url in payload: %{public}@",
                String(describing: payload)
            )
        }

        if var trace = message?["trace"] as? [String: Int64] {
            trace["nativeStart"] = nativeStart
            trace["nativeEnd"] = Int64(Date().timeIntervalSince1970 * 1000)
            message?["trace"] = trace  // Reassign the modified dictionary back
        }

        // Enable verbose logging in the content script.
        // In the real app `verbose` flag should only be true for debugging purposes.
        message?["verbose"] = true

        if let safeMessage = message {
            os_log(
                .info,
                "[WebShield] Sending response: %{public}@",
                String(describing: safeMessage)
            )
            let response = createResponse(with: safeMessage)
            context.completeRequest(
                returningItems: [response],
                completionHandler: nil
            )
        } else {
            os_log(.error, "[WebShield] No safeMessage to send in response")
            context.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    /// Converts a WebExtension.Configuration object to a dictionary payload.
    ///
    /// - Parameters:
    ///   - configuration: The WebExtension.Configuration object to convert.
    /// - Returns: A dictionary containing CSS, extended CSS, JS, and scriptlets
    ///           that should be applied to the web page.
    private func convertToPayload(
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

        return payload
    }

    /// Creates an NSExtensionItem response with the provided JSON payload.
    ///
    /// - Parameters:
    ///   - json: The JSON payload to include in the response.
    /// - Returns: An NSExtensionItem containing the response message.
    private func createResponse(with json: [String: Any?])
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
    private func getMessage(from request: NSExtensionItem?) -> [String:
        Any?]?
    {
        if request == nil {
            os_log(.error, "[WebShield] getMessage: request is nil")
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

        os_log(
            .info,
            "[WebShield] Received message from browser.runtime.sendNativeMessage: %{public}@ (profile: %{public}@)",
            String(describing: message),
            profile?.uuidString ?? "none"
        )

        if message is [String: Any?] {
            return message as? [String: Any?]
        }

        os_log(
            .error,
            "[WebShield] getMessage: message is not a dictionary: %{public}@",
            String(describing: message)
        )
        return nil
    }
}

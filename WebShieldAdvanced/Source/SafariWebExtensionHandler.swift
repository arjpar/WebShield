//
//  SafariWebExtensionHandler.swift
//  web-extension
//
//  Created by Andrey Meshkov on 17/12/2024.
//

import WebShieldService

final class SafariWebExtensionHandler: NSObject,
    NSExtensionRequestHandling
{
    public func beginRequest(with context: NSExtensionContext) {
        WebExtensionRequestHandler.beginRequest(with: context)
    }
}

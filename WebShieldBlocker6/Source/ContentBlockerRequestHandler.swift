import Foundation
import WebShieldService
import os

private let logger = Logger(
    subsystem: "arjun.webshield.contentblocker-6",
    category: "ContentBlockerRequestHandler"
)

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        ContentBlockerExtensionRequestHandler.handleRequest(
            with: context,
            groupIdentifier: GroupIdentifier.shared.value,
            rulesFilenameInAppGroup: ContentBlockerCategory.blocker6.rulesPath
        )
    }
}

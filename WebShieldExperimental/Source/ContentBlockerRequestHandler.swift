import Foundation
import os

private let logger = Logger(
    subsystem: "dev.arjuna.WebShield.DeclarativeBlockList-Experimental", category: "ContentBlockerRequestHandler")
private let specificList = "experimental.json"

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let requiredPart = "group.dev.arjuna.WebShield"

        logger.log("Content Blocker logging...")

        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: requiredPart)
        else {
            logger.log(
                "Error: Could not get container URL for group \(requiredPart)")
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        logger.log("Successfully got container URL for group \(requiredPart)")

        let blockerlistURL = containerURL.appendingPathComponent(
            "\(specificList)")

        guard FileManager.default.fileExists(atPath: blockerlistURL.path) else {
            logger.log("Content Blocker Error: \(specificList) does not exist")
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        logger.log("\(specificList) exists")

        if let attachment = NSItemProvider(contentsOf: blockerlistURL) {
            logger.log("Sending attachment")
            let item = NSExtensionItem()
            item.attachments = [attachment]
            context.completeRequest(
                returningItems: [item], completionHandler: nil)
            logger.log("Completed request")
        } else {
            logger.log(
                "Error: Could not create NSItemProvider for \(blockerlistURL)")
            context.completeRequest(returningItems: nil, completionHandler: nil)
        }

    }
}

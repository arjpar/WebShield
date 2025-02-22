import OSLog
import SafariServices

@MainActor
final class SafariWebExtensionHandler: NSObject, @preconcurrency NSExtensionRequestHandling {
    static let logger = Logger(subsystem: "dev.arjuna.WebShield.Advanced", category: "SafariWebExtensionHandler")

    func beginRequest(with context: NSExtensionContext) {
        Task {
            guard let message = context.inputItems.first as? NSExtensionItem,
                let userInfo = message.userInfo?[SFExtensionMessageKey] as? [String: Any]
            else {
                await sendErrorResponse(on: context, message: "Invalid request")
                return
            }

            SafariWebExtensionHandler.logger.info("Received native message: \(userInfo.description, privacy: .public)")

            guard let action = userInfo["action"] as? String else {
                await sendErrorResponse(on: context, message: "Missing action in request")
                return
            }

            switch action {
            case "getAdvancedBlockingData":
                await handleBlockingDataRequest(context, userInfo: userInfo)
            default:
                await sendErrorResponse(on: context, message: "Unknown action")
            }
        }
    }

    private func handleBlockingDataRequest(_ context: NSExtensionContext, userInfo: [String: Any]) async {
        guard let urlString = userInfo["url"] as? String,
            let url = URL(string: urlString)
        else {
            await sendErrorResponse(on: context, message: "Invalid URL")
            return
        }

        if let sharedEngine = ContentBlockerEngineWrapper.shared {
            do {
                let data = try await sharedEngine.getBlockingData(for: url)
                if data.utf8.count > 32_768 {
                    await sendChunkedResponse(context, url: urlString)
                } else {
                    await sendSingleResponse(on: context, data: data, url: urlString)
                }
            } catch {
                await sendErrorResponse(on: context, message: "Error getting blocking data: \(error)")
            }
        } else {
            await sendErrorResponse(on: context, message: "Engine not initialized")
        }
    }

    private func sendChunkedResponse(_ context: NSExtensionContext, url: String) async {
        do {
            guard let sharedEngine = ContentBlockerEngineWrapper.shared else {
                await sendErrorResponse(on: context, message: "Engine not initialized")
                return
            }
            let reader = try await sharedEngine.makeChunkedReader()

            let response = NSExtensionItem()
            var message: [String: Any] = [
                "url": url,
                "chunked": true,
                "more": true,
            ]

            if let chunk = await reader.nextChunk() {
                message["data"] = chunk
                message["more"] = await reader.progress < 1.0
            }

            response.userInfo = [SFExtensionMessageKey: message]
            complete(context: context, with: response)

        } catch {
            await sendErrorResponse(on: context, message: "Error in chunked response: \(error)")
        }
    }

    private func sendSingleResponse(on context: NSExtensionContext, data: String, url: String) async {
        let response = NSExtensionItem()
        response.userInfo = [
            SFExtensionMessageKey: [
                "url": url,
                "data": data,
                "chunked": false,
            ]
        ]
        complete(context: context, with: response)
    }

    private func sendErrorResponse(on context: NSExtensionContext, message: String) async {
        SafariWebExtensionHandler.logger.error("\(message)")
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["error": message]]
        complete(context: context, with: response)
    }

    private func complete(context: NSExtensionContext, with item: NSExtensionItem) {
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}

//final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
//
//    func beginRequest(with context: NSExtensionContext) {
//            // Extract the message from the JavaScript
//        guard let item = context.inputItems.first as? NSExtensionItem,
//              let userInfo = item.userInfo as? [String: Any],
//              let message = userInfo[SFExtensionMessageKey] as? [String: Any] else {
//                // No valid message; complete the request and return
//            context.completeRequest(returningItems: nil, completionHandler: nil)
//            return
//        }
//
//            // Process the message
//        if let action = message["action"] as? String,
//           let data = message["data"] as? String {
//            print("Received action: \(action), data: \(data)")
//
//                // Optional: Check profile identifier (Safari 17+)
//            if let profileIdentifier = userInfo[SFExtensionProfileKey] as? UUID {
//                print("Profile UUID: \(profileIdentifier)")
//                    // Use this for profile-specific logic if needed
//            }
//        }
//
//            // Prepare a response
//        let response = NSExtensionItem()
//        let responseData = [
//            SFExtensionMessageKey: [
//                "status": "success",
//                "reply": "Message received: \(message["data"] ?? "no data")"
//            ]
//        ]
//        response.userInfo = responseData
//
//            // Send the response back to JavaScript
//        context.completeRequest(returningItems: [response], completionHandler: nil)
//    }
//}

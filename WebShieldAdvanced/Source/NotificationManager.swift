import Foundation
import OSLog
import SafariServices

// Protocol defining notification behavior
protocol NotificationHandling {
    func notifyRulesUpdate(_ rulesData: String)
}

final class NotificationManager: NotificationHandling {
    private let logger = Logger(subsystem: "dev.arjuna.WebShield", category: "NotificationManager")
    private let queue = DispatchQueue(label: "dev.arjuna.WebShield.notificationQueue", qos: .userInitiated)
    private var pendingNotifications: [String] = []
    private var isProcessingNotifications = false
    
    func notifyRulesUpdate(_ rulesData: String) {
        queue.async { [weak self] in
            self?.handleRulesUpdate(rulesData)
        }
    }
    
    private func handleRulesUpdate(_ rulesData: String) {
        // Add the notification to the queue
        pendingNotifications.append(rulesData)
        
        // If we're not already processing notifications, start processing
        if !isProcessingNotifications {
            processNextNotification()
        }
    }
    
    private func processNextNotification() {
        guard !pendingNotifications.isEmpty else {
            isProcessingNotifications = false
            return
        }
        
        isProcessingNotifications = true
        let rulesData = pendingNotifications.removeFirst()
        
        // Create a notification context
        let context = NSExtensionContext()
        let item = NSExtensionItem()
        item.userInfo = [
            SFExtensionMessageKey: [
                "type": "rulesUpdated",
                "rulesData": rulesData
            ]
        ]
        
        // Send the notification
        context.completeRequest(returningItems: [item]) { [weak self] success in
            if !success {
                self?.logger.error("Failed to send rules update notification")
            }
            
            // Process the next notification
            self?.queue.async {
                self?.processNextNotification()
            }
        }
    }
} 

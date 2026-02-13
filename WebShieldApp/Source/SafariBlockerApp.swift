//
//  SafariBlockerApp.swift
//  WebShield
//
//  Created by Arjun on 2025-11-23.
//

//
//  SafariBlockerApp.swift
//  safari-blocker
//
//  Created by Andrey Meshkov on 10/12/2024.
//

import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(UserNotifications)
    import UserNotifications
#endif

@main
struct SafariBlockerApp: App {
    #if os(iOS) || os(visionOS)
        @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    @State private var viewModel = FilterListViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    #if os(iOS) || os(visionOS)
                        if appDelegate.hasPendingApplyNotification {
                            appDelegate.hasPendingApplyNotification = false
                            NotificationCenter.default.post(
                                name: .applyWebShieldChangesNotification,
                                object: nil
                            )
                        }
                    #endif
                }
                #if os(iOS) || os(visionOS)
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .background
                            && viewModel.hasUnappliedChanges
                        {
                            scheduleUnappliedChangesNotification()
                        }
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: .applyWebShieldChangesNotification
                        )
                    ) { _ in
                        viewModel.showRefreshSheet = true
                        Task {
                            await viewModel.refreshFilters()
                        }
                    }
                #endif
        }
    }

    #if os(iOS) || os(visionOS)
        private func scheduleUnappliedChangesNotification() {
            let content = UNMutableNotificationContent()
            content.title = "Unapplied Filter Changes"
            content.body =
                "You have unapplied filter changes in WebShield. Tap to apply them now!"
            content.sound = .default
            content.userInfo = ["action_type": "apply_webshield_changes"]

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: 1,
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request)
        }
    #endif
}

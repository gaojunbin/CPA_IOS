import SwiftUI
#if os(iOS)
import UIKit
import UserNotifications
#endif

@main
struct CPAIOSApp: App {
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var notificationRouter = NotificationRouter.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CPAAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connectionStore)
                .environmentObject(notificationRouter)
        }
    }
}

@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()

    @Published private(set) var attentionFocusRequestID = 0

    private init() {}

    func requestAttentionFocus() {
        attentionFocusRequestID += 1
    }
}

#if os(iOS)
final class CPAAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundQuotaRefreshScheduler.register()
        BackgroundQuotaRefreshScheduler.reschedule(for: ConnectionStore.loadSavedConnectionFromStorage())
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == QuotaAlertNotifier.notificationIdentifier {
            Task { @MainActor in
                NotificationRouter.shared.requestAttentionFocus()
            }
        }
        completionHandler()
    }
}

#endif

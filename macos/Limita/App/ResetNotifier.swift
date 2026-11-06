import Foundation
import UserNotifications

/// Announces a limit reset. Injected into `ResetWatcher`, so tests can record what
/// would have been announced.
@MainActor
protocol ResetNotifying: AnyObject {
    func notify(_ event: ResetEvent)
}

/// macOS notifications. Permission is asked the first time there is something to
/// announce, not at launch; clicking a notification opens the dashboard.
@MainActor
final class SystemResetNotifier: NSObject, ResetNotifying, UNUserNotificationCenterDelegate {
    static let shared = SystemResetNotifier()

    /// Called when the user clicks a notification.
    var onOpen: (() -> Void)?

    /// `UNUserNotificationCenter` needs an app bundle; `swift test` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Becomes the delegate, so clicks reach `onOpen` and banners show while Limita runs.
    func activate(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        center?.delegate = self
    }

    func notify(_ event: ResetEvent) {
        // The event's id, so the same reset never shows twice.
        notify(id: event.id, title: event.notificationTitle, body: event.notificationBody)
    }

    /// Any other announcement, such as a low DeepSeek balance.
    func notify(id: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onOpen?() }
            completionHandler()
        }
    }
}

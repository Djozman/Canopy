import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter for completion alerts.
///
/// `UNUserNotificationCenter.current()` traps when the process has no bundle
/// identifier (e.g. when launched via `swift run` instead of Canopy.app), so
/// every entry point is guarded on `Bundle.main.bundleIdentifier`.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

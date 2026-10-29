import AppKit
import UserNotifications

/// macOS notifications for the on-demand limit.
enum LimitNotifier {
    private static let identifier = "cursor-usage-limit"
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    /// `UNUserNotificationCenter` crashes outside an app bundle, as with `swift run`.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks for permission the first time; opens System Settings if it was denied before.
    static func requestPermission() async -> Bool {
        guard isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .denied {
            NSWorkspace.shared.open(settingsURL)
            return false
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(title: String, body: String) async {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

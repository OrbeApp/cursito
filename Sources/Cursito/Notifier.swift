import AppKit
import UserNotifications

/// macOS notifications: spend warnings, new exports from the other Mac and sync results.
enum Notifier {
    enum Kind: String {
        case usageLimit = "cursor-usage-limit"
        case usageForecast = "cursor-usage-forecast"
        case newExport = "cursor-new-export"
        case syncResult = "cursor-sync-result"
    }

    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    /// `UNUserNotificationCenter` crashes outside an app bundle, as with `swift run`.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// For a setting the user turns on: asks the first time, opens System Settings if it was denied before.
    static func requestPermission() async -> Bool {
        guard isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .denied {
            NSWorkspace.shared.open(settingsURL)
            return false
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Posts when allowed; the first time, macOS asks. A later notification of the same kind replaces it.
    static func post(_ kind: Kind, title: String, body: String) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        case .denied:
            return
        default:
            break
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil))
    }
}

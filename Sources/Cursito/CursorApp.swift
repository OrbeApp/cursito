import AppKit

/// Quits Cursor before an import and reopens it afterwards: an import can't run while
/// Cursor is open, because Cursor rewrites its settings and state when it quits.
@MainActor
enum CursorApp {
    static let bundleIdentifier = "com.todesktop.230313mzl4w4u92"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Asks Cursor to quit and waits for it. Returns false if it's still open after
    /// `timeout`, e.g. because it's showing an unsaved-changes prompt.
    static func quit(timeout: Duration = .seconds(30)) async -> Bool {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        instances.forEach { $0.terminate() }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if instances.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return instances.allSatisfy(\.isTerminated)
    }

    static func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

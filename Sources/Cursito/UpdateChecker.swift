import AppKit
import CursitoCore
import Observation

/// Looks for a newer Cursito release on GitHub at launch and then once a day.
@MainActor
@Observable
final class UpdateChecker {
    private static let checkEvery: TimeInterval = 24 * 60 * 60
    private static let pollInterval: Duration = .seconds(60 * 60)

    private(set) var available: Release?
    private var lastChecked: Date?
    private let checker = ReleaseChecker()

    /// Nil under `swift run`, which has no Info.plist to read the version from.
    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap(SemanticVersion.init)

    init() {
        guard currentVersion != nil else { return }
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfStale()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func checkIfStale() async {
        guard let currentVersion else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkEvery { return }
        do {
            available = try await checker.newerRelease(than: currentVersion)
            lastChecked = Date()
        } catch {
            // Offline or rate limited by GitHub: retried at the next poll.
        }
    }

    func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.pageURL)
    }
}

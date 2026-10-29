import AppKit
import CursitoCore
import Observation

/// Running and recently ended cloud agents, from Cursor's Cloud Agents API.
///
/// The user API key stays in the keychain and is only read for a refresh. It could
/// launch agents, but `CloudAgentsAPI` only sends GET requests.
@MainActor
@Observable
final class CloudAgentsModel {
    private static let connectedKey = "cloudAgentsConnected"
    private static let accountKey = "cloudAgentsAccount"
    private static let notifiesKey = "cloudAgentsNotifyRunEnd"
    private static let runningInterval: TimeInterval = 60
    private static let idleInterval: TimeInterval = 5 * 60
    /// Opening the menu refreshes when the last refresh is older than this.
    private static let staleAfter: TimeInterval = 30
    /// How long an ended run stays in the menu.
    static let recentWindow: TimeInterval = 24 * 60 * 60
    private static let checkInterval: Duration = .seconds(15)

    private(set) var isConnected: Bool
    /// The key owner's email, or the key's name for a service account key.
    private(set) var account: String
    private(set) var isLoading = false
    private(set) var activities: [CloudAgentActivity] = []
    private(set) var lastUpdated: Date?
    private(set) var problem: String?
    private(set) var notifiesWhenRunsEnd: Bool {
        didSet { UserDefaults.standard.set(notifiesWhenRunsEnd, forKey: Self.notifiesKey) }
    }

    /// The last successful refresh, to tell which runs ended since.
    private var snapshot: CloudAgentsSnapshot?
    private var nextRefreshAt = Date.distantPast
    /// Set from `Retry-After` when Cursor rate limits; no request goes out before it.
    private var rateLimitedUntil: Date?

    init() {
        isConnected = UserDefaults.standard.bool(forKey: Self.connectedKey)
        account = UserDefaults.standard.string(forKey: Self.accountKey) ?? ""
        notifiesWhenRunsEnd = UserDefaults.standard.object(forKey: Self.notifiesKey) as? Bool ?? true
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfDue()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    var running: [CloudAgentActivity] { activities.filter(\.isRunning) }

    /// Agents whose latest run ended in the last 24 hours, most recent first.
    var recent: [CloudAgentActivity] {
        let since = Date().addingTimeInterval(-Self.recentWindow)
        return activities
            .filter { ($0.endedAt ?? .distantPast) >= since }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    /// For the menu opening: refreshes unless it just did or Cursor asked to wait.
    func refreshIfStale() async {
        guard isConnected else { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.staleAfter { return }
        await refresh()
    }

    private func refreshIfDue() async {
        guard isConnected, Date() >= nextRefreshAt else { return }
        await refresh()
    }

    func refresh() async {
        guard isConnected, !isLoading else { return }
        if let rateLimitedUntil, Date() < rateLimitedUntil { return }
        guard let apiKey = KeychainItem.cursorUserAPIKey.read() else {
            problem = "Cursito couldn't read the API key from the keychain. Connect it again."
            return
        }
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        do {
            let activities = try await CloudAgentsAPI(apiKey: apiKey)
                .activity(reusing: self.activities, now: now, window: Self.recentWindow)
            guard isConnected else { return }
            let current = CloudAgentsSnapshot(takenAt: now, activities: activities)
            let ended = current.endedRuns(since: snapshot)
            snapshot = current
            self.activities = activities
            lastUpdated = now
            problem = nil
            rateLimitedUntil = nil
            scheduleNextRefresh()
            await notify(about: ended)
        } catch CloudAgentsAPI.Failure.rateLimited(let retryAfter) {
            let until = Date().addingTimeInterval(max(retryAfter ?? 2 * Self.runningInterval, Self.runningInterval))
            rateLimitedUntil = until
            nextRefreshAt = until
            problem = CloudAgentsAPI.Failure.rateLimited(retryAfter: retryAfter).localizedDescription
        } catch {
            problem = error.localizedDescription
            scheduleNextRefresh()
        }
    }

    /// Every minute while an agent runs, every 5 minutes otherwise.
    private func scheduleNextRefresh() {
        nextRefreshAt = Date().addingTimeInterval(running.isEmpty ? Self.idleInterval : Self.runningInterval)
    }

    /// Checks the key with `GET /v1/me` before keeping it. Returns an error message when it doesn't work.
    func connect(apiKey: String) async -> String? {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return "Paste the API key." }

        let me: CloudAgentsAccount
        do {
            me = try await CloudAgentsAPI(apiKey: apiKey).me()
            try KeychainItem.cursorUserAPIKey.save(apiKey)
        } catch {
            return error.localizedDescription
        }

        reset()
        account = me.displayName
        isConnected = true
        UserDefaults.standard.set(account, forKey: Self.accountKey)
        UserDefaults.standard.set(true, forKey: Self.connectedKey)
        await refresh()
        return nil
    }

    func disconnect() {
        KeychainItem.cursorUserAPIKey.delete()
        UserDefaults.standard.removeObject(forKey: Self.connectedKey)
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        isConnected = false
        account = ""
        reset()
    }

    private func reset() {
        activities = []
        snapshot = nil
        lastUpdated = nil
        problem = nil
        rateLimitedUntil = nil
        nextRefreshAt = .distantPast
    }

    /// Turning notifications on asks macOS for permission first.
    func setNotifiesWhenRunsEnd(_ isOn: Bool) async {
        notifiesWhenRunsEnd = isOn ? await Notifier.requestPermission() : false
    }

    /// One notification per refresh, since a later one of the same kind replaces it.
    private func notify(about ended: [CloudAgentActivity]) async {
        guard notifiesWhenRunsEnd, let first = ended.first else { return }
        let failed = ended.filter { $0.run?.status == .error }.count

        if ended.count == 1 {
            let title = failed == 0 ? "Cloud agent finished: \(first.title)" : "Cloud agent failed: \(first.title)"
            await Notifier.post(.cloudAgentRun, title: title, body: Self.detail(of: first))
            return
        }
        let title = failed == 0
            ? "\(ended.count) cloud agents finished"
            : "\(ended.count) cloud agents ended, \(failed) failed"
        await Notifier.post(.cloudAgentRun, title: title, body: ended.map(\.title).shortListText + ".")
    }

    /// "org/repo · cursor/fix-login · PR #123", or the start of the agent's reply.
    private static func detail(of activity: CloudAgentActivity) -> String {
        var parts = [activity.location].compactMap(\.self)
        if let prURL = activity.prURL {
            parts.append(Int(prURL.lastPathComponent).map { "PR #\($0)" } ?? "PR opened")
        }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let result = activity.run?.result?.split(whereSeparator: \.isNewline).first {
            return String(result.prefix(140))
        }
        return "Open it from Cursito."
    }
}

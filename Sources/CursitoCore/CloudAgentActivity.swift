import Foundation

/// A cloud agent with its latest run: what the menu shows for one agent.
public struct CloudAgentActivity: Sendable, Equatable, Identifiable {
    public let agent: CloudAgent
    public let run: CloudAgentRun?
    /// The repos the agent was launched on, fetched only while it hasn't pushed a branch.
    public let repos: [CloudAgent.Repo]?

    public init(agent: CloudAgent, run: CloudAgentRun?, repos: [CloudAgent.Repo]? = nil) {
        self.agent = agent
        self.run = run
        self.repos = repos
    }

    public var id: String { agent.id }

    public var title: String { agent.name ?? "Untitled agent" }

    public var isRunning: Bool {
        if let run { return run.status.isActive }
        return agent.status == .active
    }

    /// When the latest run ended, if it has.
    public var endedAt: Date? {
        guard let run, run.status.hasEnded else { return nil }
        return run.updatedAt ?? agent.updatedAt
    }

    /// "org/repo", from the pushed branch or else the launch repo.
    public var repoName: String? {
        let url = run?.branches.first?.repoURL ?? repos?.first?.url
        return url.flatMap(Self.shortRepoName)
    }

    public var branch: String? { run?.branches.first?.branch }

    public var prURL: URL? { run?.branches.lazy.compactMap(\.prURL).first }

    /// "org/repo · cursor/fix-login"
    public var location: String? {
        let parts = [repoName, branch].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The last two path components of `github.com/org/repo` or `https://gitlab.example.com/group/repo.git`.
    static func shortRepoName(_ url: String) -> String? {
        var path = url
        if let range = path.range(of: "://") { path = String(path[range.upperBound...]) }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let components = path.split(separator: "/").dropFirst()
        guard !components.isEmpty else { return nil }
        return components.suffix(2).joined(separator: "/")
    }
}

/// The agents as seen at one refresh, to tell which runs ended since the previous one.
public struct CloudAgentsSnapshot: Sendable, Equatable {
    public let takenAt: Date
    public let activities: [CloudAgentActivity]

    public init(takenAt: Date, activities: [CloudAgentActivity]) {
        self.takenAt = takenAt
        self.activities = activities
    }

    /// Agents whose latest run finished or failed since `previous`. Nothing for the first
    /// snapshot, and each run at most once: a run that had already ended in `previous`,
    /// or that ended before it was taken, isn't new. Cancelled and expired runs aren't reported.
    public func endedRuns(since previous: CloudAgentsSnapshot?) -> [CloudAgentActivity] {
        guard let previous else { return [] }
        let previousRuns = Dictionary(
            previous.activities.compactMap { activity in activity.run.map { ($0.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return activities.filter { activity in
            guard let run = activity.run, run.status == .finished || run.status == .error else { return false }
            if let before = previousRuns[run.id] {
                return !before.status.hasEnded
            }
            return (activity.endedAt ?? .distantPast) > previous.takenAt
        }
    }
}

extension CloudAgentsAPI {
    /// Agents that are running or were updated within `window`, newest first, each with
    /// its latest run. Runs that had already ended in `previous` are reused while the agent
    /// doesn't change, so a quiet refresh is a single request.
    public func activity(
        reusing previous: [CloudAgentActivity] = [],
        now: Date = Date(),
        window: TimeInterval = 24 * 60 * 60,
        maxAgents: Int = 8,
        maxPages: Int = 3
    ) async throws -> [CloudAgentActivity] {
        let since = now.addingTimeInterval(-window)
        func isRelevant(_ agent: CloudAgent) -> Bool {
            agent.status == .active || (agent.updatedAt ?? .distantPast) >= since
        }

        var agents: [CloudAgent] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await self.agents(limit: 50, cursor: cursor)
            agents += page.agents
            cursor = page.nextCursor
            guard cursor != nil, let last = page.agents.last, isRelevant(last) else { break }
        }

        let relevant = agents.filter(isRelevant)
            .sorted { ($0.status == .active ? 0 : 1, $1.updatedAt ?? .distantPast) < ($1.status == .active ? 0 : 1, $0.updatedAt ?? .distantPast) }
            .prefix(maxAgents)
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [CloudAgentActivity] = []
        for agent in relevant {
            let before = known[agent.id]
            let run = try await latestRun(of: agent, before: before)
            var repos = before?.repos
            if repos == nil, run?.branches.isEmpty ?? true {
                repos = try await self.agent(id: agent.id).repos ?? []
            }
            result.append(CloudAgentActivity(agent: agent, run: run, repos: repos))
        }
        return result.sorted { ($0.agent.updatedAt ?? .distantPast) > ($1.agent.updatedAt ?? .distantPast) }
    }

    private func latestRun(of agent: CloudAgent, before: CloudAgentActivity?) async throws -> CloudAgentRun? {
        guard let runID = agent.latestRunID else { return nil }
        if let cached = before?.run, cached.id == runID, cached.status.hasEnded,
           before?.agent.updatedAt == agent.updatedAt {
            return cached
        }
        do {
            return try await run(agentID: agent.id, runID: runID)
        } catch Failure.server(status: 404) {
            return nil
        }
    }
}

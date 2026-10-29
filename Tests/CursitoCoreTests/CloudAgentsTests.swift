import Foundation
import Testing
@testable import CursitoCore

struct CloudAgentsAPITests {
    private static func respond(_ status: Int, _ body: String, headers: [String: String]? = nil) -> CloudAgentsAPI.Transport {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    /// Answers by path, failing the test on anything that isn't a GET.
    private static func routes(_ bodies: [String: String], log: RequestLog? = nil) -> CloudAgentsAPI.Transport {
        { request in
            #expect(request.httpMethod == "GET")
            let path = request.url?.path ?? ""
            log?.append(path)
            guard let body = bodies[path] else {
                Issue.record("Unexpected request to \(path)")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let listJSON = """
    {
      "items": [
        {"id": "bc-1", "name": "Add README with setup instructions", "status": "ACTIVE", "env": {"type": "cloud"},
         "url": "https://cursor.com/agents/bc-1", "createdAt": "2026-04-13T18:30:00.000Z",
         "updatedAt": "2026-04-13T18:45:00.000Z", "latestRunId": "run-1"},
        {"id": "bc-2", "status": "HIBERNATING", "url": "javascript:alert(1)", "createdAt": "2026-04-13T17:00:00Z",
         "updatedAt": "2026-04-13T17:10:00Z", "futureField": {"nested": true}},
        {"name": "no id, skipped"}
      ],
      "nextCursor": "bc-3"
    }
    """

    static let runJSON = """
    {
      "id": "run-1", "agentId": "bc-1", "status": "FINISHED",
      "createdAt": "2026-04-13T18:30:00.000Z", "updatedAt": "2026-04-13T18:45:00.000Z",
      "durationMs": 12357, "result": "Added README.md with installation instructions and usage examples.",
      "git": {"branches": [{"repoUrl": "github.com/your-org/your-repo", "branch": "cursor/add-readme-a1b2",
                            "prUrl": "https://github.com/your-org/your-repo/pull/123"}]}
    }
    """

    @Test func listsAgentsWithBasicAuthAndLenientItems() async throws {
        let api = CloudAgentsAPI(apiKey: "key_test") { request in
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic a2V5X3Rlc3Q6")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            #expect(components?.path == "/v1/agents")
            #expect(components?.queryItems?.contains(URLQueryItem(name: "limit", value: "100")) == true)
            #expect(components?.queryItems?.contains(URLQueryItem(name: "includeArchived", value: "false")) == true)
            #expect(components?.queryItems?.contains(URLQueryItem(name: "cursor", value: "bc-0")) == true)
            return try await Self.respond(200, Self.listJSON)(request)
        }

        let page = try await api.agents(limit: 500, cursor: "bc-0")

        #expect(page.nextCursor == "bc-3")
        #expect(page.agents.map(\.id) == ["bc-1", "bc-2"])
        let first = page.agents[0]
        #expect(first.status == .active)
        #expect(first.url?.absoluteString == "https://cursor.com/agents/bc-1")
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_776_105_000))
        #expect(first.latestRunID == "run-1")
        #expect(first.repos == nil)
        let second = page.agents[1]
        #expect(second.name == nil)
        #expect(second.status == .unknown("HIBERNATING"))
        #expect(second.url == nil)
        #expect(second.updatedAt == Date(timeIntervalSince1970: 1_776_100_200))
    }

    @Test func decodesARunWithBranchesAndUnknownStatuses() throws {
        let run = try JSONDecoder().decode(CloudAgentRun.self, from: Data(Self.runJSON.utf8))
        #expect(run.status == .finished && run.status.hasEnded && !run.status.isActive)
        #expect(run.durationMs == 12357)
        #expect(run.branches.first?.branch == "cursor/add-readme-a1b2")
        #expect(run.branches.first?.prURL?.absoluteString == "https://github.com/your-org/your-repo/pull/123")

        let odd = try JSONDecoder().decode(CloudAgentRun.self, from: Data("""
        {"id": "run-9", "status": "PAUSED", "git": {"branches": [{"branch": "x"}, 42]}}
        """.utf8))
        #expect(odd.status == .unknown("PAUSED"))
        #expect(!odd.status.isActive && !odd.status.hasEnded)
        #expect(odd.branches.count == 1)
        #expect(odd.createdAt == nil)

        let active = try JSONDecoder().decode(CloudAgentRun.self, from: Data(#"{"id": "r", "status": "WAITING_FOR_BACKGROUND_WORK"}"#.utf8))
        #expect(active.status == .waitingForBackgroundWork && active.status.isActive)
    }

    @Test func decodesTheAccountOfUserAndServiceAccountKeys() async throws {
        let user = try await CloudAgentsAPI(apiKey: "k", transport: Self.routes(["/v1/me": """
        {"apiKeyName": "Cursito", "userId": 42, "createdAt": "2026-04-13T18:30:00.000Z",
         "userEmail": "developer@example.com", "userFirstName": "Alex", "userLastName": "Rivera"}
        """])).me()
        #expect(user.email == "developer@example.com")
        #expect(user.name == "Alex Rivera")
        #expect(user.displayName == "developer@example.com")

        let service = try await CloudAgentsAPI(apiKey: "k", transport: Self.routes(["/v1/me": """
        {"apiKeyName": "Production Service Account", "createdAt": "2026-04-13T18:30:00.000Z"}
        """])).me()
        #expect(service.email == nil && service.name == nil)
        #expect(service.displayName == "Production Service Account")
    }

    @Test func httpErrorsMapToFailures() async {
        let cases: [(Int, [String: String]?, String, CloudAgentsAPI.Failure)] = [
            (401, nil, #"{"code": "error", "message": "Invalid User API Key"}"#, .unauthorized),
            (403, nil, #"{"error": {"code": "plan_required", "message": "Cloud Agents need a paid plan"}}"#, .forbidden("Cloud Agents need a paid plan")),
            (403, nil, "", .forbidden(nil)),
            (429, ["Retry-After": "90"], #"{"error": {"code": "rate_limit_exceeded", "message": "Slow down"}}"#, .rateLimited(retryAfter: 90)),
            (429, nil, "{}", .rateLimited(retryAfter: nil)),
            (502, nil, "<html>", .server(status: 502)),
            (200, nil, "<html>", .invalidResponse),
        ]
        for (status, headers, body, failure) in cases {
            let api = CloudAgentsAPI(apiKey: "k", transport: Self.respond(status, body, headers: headers))
            await #expect(throws: failure) { try await api.me() }
        }
    }

    @Test func readsRetryAfterAsSecondsOrADate() {
        let now = Date(timeIntervalSince1970: 1_776_105_000)
        #expect(CloudAgentsAPI.retryAfter("60", now: now) == 60)
        #expect(CloudAgentsAPI.retryAfter("Mon, 13 Apr 2026 18:32:00 GMT", now: now) == 120)
        #expect(CloudAgentsAPI.retryAfter("soon", now: now) == nil)
        #expect(CloudAgentsAPI.retryAfter(nil, now: now) == nil)
    }

    @Test func idsAreEncodedAsSinglePathComponents() async throws {
        let api = CloudAgentsAPI(apiKey: "k") { request in
            #expect(request.url?.absoluteString == "https://api.cursor.com/v1/agents/bc-1%2F..%2Fx/runs/run%201")
            return try await Self.respond(200, Self.runJSON)(request)
        }
        _ = try await api.run(agentID: "bc-1/../x", runID: "run 1")
    }

    @Test func activityFetchesRunsAndReusesEndedOnes() async throws {
        let now = Date(timeIntervalSince1970: 1_776_106_000) // 2026-04-13T18:46:40Z
        let log = RequestLog()
        let bodies = [
            "/v1/agents": """
            {"items": [
              {"id": "bc-1", "name": "Add README", "status": "IDLE", "url": "https://cursor.com/agents/bc-1",
               "updatedAt": "2026-04-13T18:45:00.000Z", "latestRunId": "run-1"},
              {"id": "bc-2", "name": "Fix login", "status": "ACTIVE", "updatedAt": "2026-04-12T08:00:00.000Z", "latestRunId": "run-2"},
              {"id": "bc-old", "name": "Old", "status": "IDLE", "updatedAt": "2026-04-01T08:00:00.000Z", "latestRunId": "run-old"}
            ], "nextCursor": "bc-older"}
            """,
            "/v1/agents/bc-1/runs/run-1": Self.runJSON,
            "/v1/agents/bc-2/runs/run-2": #"{"id": "run-2", "agentId": "bc-2", "status": "RUNNING"}"#,
            "/v1/agents/bc-2": #"{"id": "bc-2", "status": "ACTIVE", "repos": [{"url": "https://github.com/OrbeApp/cursito", "startingRef": "develop"}]}"#,
        ]
        let api = CloudAgentsAPI(apiKey: "k", transport: Self.routes(bodies, log: log))

        let first = try await api.activity(now: now)

        #expect(first.map(\.id) == ["bc-1", "bc-2"])
        #expect(first[0].endedAt == Date(timeIntervalSince1970: 1_776_105_900))
        #expect(first[0].location == "your-org/your-repo · cursor/add-readme-a1b2")
        #expect(first[1].isRunning)
        #expect(first[1].location == "OrbeApp/cursito")
        // Running agents first; the page ended with an old agent, so the next page isn't fetched.
        #expect(log.paths == ["/v1/agents", "/v1/agents/bc-2/runs/run-2", "/v1/agents/bc-2", "/v1/agents/bc-1/runs/run-1"])

        log.paths = []
        _ = try await api.activity(reusing: first, now: now)
        #expect(log.paths == ["/v1/agents", "/v1/agents/bc-2/runs/run-2"])
    }
}

struct CloudAgentsSnapshotTests {
    private static let start = Date(timeIntervalSince1970: 1_776_105_000)

    private static func activity(_ agentID: String, run runID: String?, _ status: String, endedMinutesIn minutes: Double = 0) throws -> CloudAgentActivity {
        let updated = start.addingTimeInterval(minutes * 60).formatted(.iso8601)
        let agent = try JSONDecoder().decode(CloudAgent.self, from: Data("""
        {"id": "\(agentID)", "name": "Agent \(agentID)", "status": "ACTIVE", "updatedAt": "\(updated)"}
        """.utf8))
        let run = try runID.map { id in
            try JSONDecoder().decode(CloudAgentRun.self, from: Data("""
            {"id": "\(id)", "agentId": "\(agentID)", "status": "\(status)", "updatedAt": "\(updated)"}
            """.utf8))
        }
        return CloudAgentActivity(agent: agent, run: run)
    }

    private static func snapshot(minutes: Double, _ activities: [CloudAgentActivity]) -> CloudAgentsSnapshot {
        CloudAgentsSnapshot(takenAt: start.addingTimeInterval(minutes * 60), activities: activities)
    }

    @Test func nothingOnTheFirstLoad() throws {
        let first = Self.snapshot(minutes: 1, [
            try Self.activity("a", run: "r1", "FINISHED"),
            try Self.activity("b", run: "r2", "ERROR"),
        ])
        #expect(first.endedRuns(since: nil).isEmpty)
    }

    @Test func reportsRunsThatFinishedOrFailedOnce() throws {
        let before = Self.snapshot(minutes: 1, [
            try Self.activity("a", run: "r1", "RUNNING"),
            try Self.activity("b", run: "r2", "CREATING"),
            try Self.activity("c", run: "r3", "RUNNING"),
            try Self.activity("d", run: "r4", "FINISHED"),
        ])
        let after = Self.snapshot(minutes: 2, [
            try Self.activity("a", run: "r1", "FINISHED", endedMinutesIn: 1.5),
            try Self.activity("b", run: "r2", "ERROR", endedMinutesIn: 1.5),
            try Self.activity("c", run: "r3", "CANCELLED", endedMinutesIn: 1.5),
            try Self.activity("d", run: "r4", "FINISHED"),
        ])
        #expect(after.endedRuns(since: before).map(\.id) == ["a", "b"])

        let later = Self.snapshot(minutes: 3, after.activities)
        #expect(later.endedRuns(since: after).isEmpty)
    }

    @Test func reportsRunsThatStartedAndEndedBetweenRefreshes() throws {
        let before = Self.snapshot(minutes: 5, [try Self.activity("a", run: "r1", "FINISHED")])
        let after = Self.snapshot(minutes: 10, [
            try Self.activity("a", run: "r2", "FINISHED", endedMinutesIn: 7),
            try Self.activity("new", run: "r3", "ERROR", endedMinutesIn: 8),
            // Ended before the previous refresh and only showed up now: not new.
            try Self.activity("late", run: "r4", "FINISHED", endedMinutesIn: 2),
        ])
        #expect(after.endedRuns(since: before).map(\.id) == ["a", "new"])
    }

    @Test func unknownStatusesAreNeitherRunningNorEnded() throws {
        let odd = try Self.activity("a", run: "r1", "SOMETHING_NEW")
        #expect(!odd.isRunning)
        #expect(odd.endedAt == nil)
        let before = Self.snapshot(minutes: 1, [try Self.activity("a", run: "r1", "RUNNING")])
        #expect(Self.snapshot(minutes: 2, [odd]).endedRuns(since: before).isEmpty)
    }

    @Test func shortensRepoURLs() {
        #expect(CloudAgentActivity.shortRepoName("github.com/OrbeApp/cursito") == "OrbeApp/cursito")
        #expect(CloudAgentActivity.shortRepoName("https://gitlab.example.com/group/sub/repo.git") == "sub/repo")
        #expect(CloudAgentActivity.shortRepoName("github.com") == nil)
    }
}

/// Collects request paths from a `@Sendable` transport.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func append(_ path: String) {
        lock.withLock { storage.append(path) }
    }
}

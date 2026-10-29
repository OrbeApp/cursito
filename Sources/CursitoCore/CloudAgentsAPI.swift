import Foundation

/// Read-only client for Cursor's Cloud Agents API v1 (public beta,
/// https://cursor.com/docs/cloud-agent/api/endpoints).
///
/// It takes a user API key, which can also launch agents and spend money, so
/// this client only sends GET requests: there's no way to create, follow up,
/// cancel, archive or delete an agent through it.
public struct CloudAgentsAPI: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum Failure: Error, Equatable, LocalizedError {
        case unauthorized
        /// With Cursor's message when it sends one (plan required, feature unavailable…).
        case forbidden(String?)
        /// `Retry-After` in seconds, when Cursor sends it.
        case rateLimited(retryAfter: TimeInterval?)
        case server(status: Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .unauthorized:
                "Cursor rejected the API key. Cloud agents need a user API key from the Cursor dashboard, not an Admin API key."
            case .forbidden(let message):
                message.map { "Cursor won't show cloud agents for this key: \($0)" }
                    ?? "This key can't read cloud agents. Your plan may not include them."
            case .rateLimited:
                "Cursor's API is rate limiting requests. Cursito will try again later."
            case .server(let status):
                "Cursor's API answered with HTTP \(status)."
            case .invalidResponse:
                "Cursor's API sent a response Cursito doesn't understand."
            }
        }
    }

    public static let defaultBaseURL = URL(string: "https://api.cursor.com")!

    private let apiKey: String
    private let baseURL: URL
    private let transport: Transport

    public init(apiKey: String, baseURL: URL = Self.defaultBaseURL, transport: Transport? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    /// Who the key belongs to; also how a key is checked before it's saved.
    public func me() async throws -> CloudAgentsAccount {
        try await get(baseURL.appending(path: "v1/me"))
    }

    /// One page of agents, newest first.
    public func agents(limit: Int = 20, cursor: String? = nil, includeArchived: Bool = false) async throws -> CloudAgentsPage {
        var query = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "includeArchived", value: includeArchived ? "true" : "false"),
        ]
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get(baseURL.appending(path: "v1/agents").appending(queryItems: query))
    }

    /// The full agent record, which adds the repos it was launched on.
    public func agent(id: String) async throws -> CloudAgent {
        try await get(baseURL.appending(path: "v1/agents").appending(component: id))
    }

    public func run(agentID: String, runID: String) async throws -> CloudAgentRun {
        try await get(baseURL.appending(path: "v1/agents").appending(component: agentID)
            .appending(path: "runs").appending(component: runID))
    }

    private func get<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Basic " + Data("\(apiKey):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw Failure.unauthorized
        case 403: throw Failure.forbidden(Self.errorMessage(in: data))
        case 429: throw Failure.rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default: throw Failure.server(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Failure.invalidResponse
        }
    }

    /// `{"error": {"code", "message"}}`, or `{"code", "message"}` for authentication errors.
    static func errorMessage(in data: Data) -> String? {
        struct Body: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
            let message: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        return [body?.error?.message, body?.message].compactMap(\.self).first { !$0.isEmpty }
    }

    /// Seconds, or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max($0.timeIntervalSince(now), 0) }
    }
}

/// `GET /v1/me`. Service account keys have no user, only a key name.
public struct CloudAgentsAccount: Decodable, Sendable, Equatable {
    public let keyName: String?
    public let email: String?
    public let name: String?

    /// What to show for "connected as".
    public var displayName: String {
        email ?? name ?? keyName ?? "Cursor API key"
    }

    private enum CodingKeys: String, CodingKey {
        case apiKeyName, userEmail, userFirstName, userLastName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyName = container.nonEmptyString(.apiKeyName)
        email = container.nonEmptyString(.userEmail)
        let name = [container.nonEmptyString(.userFirstName), container.nonEmptyString(.userLastName)]
            .compactMap(\.self)
            .joined(separator: " ")
        self.name = name.isEmpty ? nil : name
    }
}

/// A page of `GET /v1/agents`; `nextCursor` is nil on the last page.
public struct CloudAgentsPage: Decodable, Sendable {
    public let agents: [CloudAgent]
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items, nextCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = (try? container.decodeIfPresent([Lenient<CloudAgent>].self, forKey: .items))?.compactMap(\.value) ?? []
        nextCursor = container.nonEmptyString(.nextCursor)
    }
}

/// A durable cloud agent. What it's doing right now lives on its latest run.
public struct CloudAgent: Decodable, Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// A turn is running, waiting on background work or about to start.
        case active
        /// The last turn ended; it accepts follow-ups.
        case idle
        case archived
        case unknown(String)

        init(_ raw: String?) {
            switch raw?.uppercased() {
            case "ACTIVE": self = .active
            case "IDLE": self = .idle
            case "ARCHIVED": self = .archived
            default: self = .unknown(raw ?? "")
            }
        }
    }

    public struct Repo: Decodable, Sendable, Equatable {
        public let url: String
        public let startingRef: String?

        private enum CodingKeys: String, CodingKey {
            case url, startingRef
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = container.nonEmptyString(.url) ?? ""
            startingRef = container.nonEmptyString(.startingRef)
        }
    }

    public let id: String
    /// Derived from the prompt by Cursor when the launch didn't name it; can be missing.
    public let name: String?
    public let status: Status
    /// The agent in Cursor's web app.
    public let url: URL?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let latestRunID: String?
    /// Only in `GET /v1/agents/{id}`; nil in list items.
    public let repos: [Repo]?

    private enum CodingKeys: String, CodingKey {
        case id, name, status, url, createdAt, updatedAt, latestRunId, repos
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.nonEmptyString(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Agent without an id")
        }
        self.id = id
        name = container.nonEmptyString(.name)
        status = Status(container.nonEmptyString(.status))
        url = container.webURL(.url)
        createdAt = container.lenientDate(.createdAt)
        updatedAt = container.lenientDate(.updatedAt)
        latestRunID = container.nonEmptyString(.latestRunId)
        repos = (try? container.decodeIfPresent([Lenient<Repo>].self, forKey: .repos))?.compactMap(\.value)
    }
}

/// One prompt submitted to an agent: the launch or a follow-up.
public struct CloudAgentRun: Decodable, Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case creating, running, waitingForBackgroundWork
        case finished, error, cancelled, expired
        case unknown(String)

        init(_ raw: String?) {
            switch raw?.uppercased() {
            case "CREATING": self = .creating
            case "RUNNING": self = .running
            case "WAITING_FOR_BACKGROUND_WORK": self = .waitingForBackgroundWork
            case "FINISHED": self = .finished
            case "ERROR": self = .error
            case "CANCELLED": self = .cancelled
            case "EXPIRED": self = .expired
            default: self = .unknown(raw ?? "")
            }
        }

        public var isActive: Bool {
            switch self {
            case .creating, .running, .waitingForBackgroundWork: true
            default: false
            }
        }

        public var hasEnded: Bool {
            switch self {
            case .finished, .error, .cancelled, .expired: true
            default: false
            }
        }
    }

    /// A branch the agent pushed. Per agent: every run of an agent reports the same ones.
    public struct Branch: Decodable, Sendable, Equatable {
        /// Without the scheme, e.g. `github.com/org/repo`.
        public let repoURL: String
        public let branch: String?
        public let prURL: URL?

        private enum CodingKeys: String, CodingKey {
            case repoUrl, branch, prUrl
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            repoURL = container.nonEmptyString(.repoUrl) ?? ""
            branch = container.nonEmptyString(.branch)
            prURL = container.webURL(.prUrl)
        }
    }

    public let id: String
    public let agentID: String
    public let status: Status
    public let createdAt: Date?
    public let updatedAt: Date?
    public let durationMs: Int?
    /// The final reply, once the run has ended.
    public let result: String?
    public let branches: [Branch]

    private enum CodingKeys: String, CodingKey {
        case id, agentId, status, createdAt, updatedAt, durationMs, result, git
    }

    private struct Git: Decodable {
        let branches: [Lenient<Branch>]?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.nonEmptyString(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Run without an id")
        }
        self.id = id
        agentID = container.nonEmptyString(.agentId) ?? ""
        status = Status(container.nonEmptyString(.status))
        createdAt = container.lenientDate(.createdAt)
        updatedAt = container.lenientDate(.updatedAt)
        durationMs = container.lenientInt(.durationMs)
        result = container.nonEmptyString(.result)
        branches = (try? container.decodeIfPresent(Git.self, forKey: .git))?.branches?.compactMap(\.value) ?? []
    }
}

/// Decodes an array element as nil instead of failing the whole array.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func nonEmptyString(_ key: Key) -> String? {
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ISO 8601 with or without fractional seconds, or epoch milliseconds.
    func lenientDate(_ key: Key) -> Date? {
        if let text = nonEmptyString(key) {
            for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
                if let date = try? Date(text, strategy: style) { return date }
            }
        }
        return lenientDouble(key).map(Date.init(epochMilliseconds:))
    }

    /// Only http(s), since these URLs end up opened in the browser.
    func webURL(_ key: Key) -> URL? {
        guard let text = nonEmptyString(key), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

import Foundation

/// Read-only client for the spend and usage endpoints of Cursor's Admin API.
///
/// The Admin API is Cursor's documented API for Enterprise teams
/// (https://cursor.com/docs/account/teams/admin-api). Its keys carry the `admin:*`
/// scope and can also change the team, so this client only exposes reads.
public struct CursorAdminAPI: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum Failure: Error, Equatable, LocalizedError {
        case unauthorized
        case forbidden
        case rateLimited
        case server(status: Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .unauthorized:
                "Cursor rejected the API key."
            case .forbidden:
                "This key can't read usage. The Admin API needs an Enterprise team and an admin key."
            case .rateLimited:
                "Cursor's API is rate limiting requests. Try again in a minute."
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

    /// Spend in the current billing cycle, one row per team member.
    /// `searchTerm` matches names and emails as a substring.
    public func spend(searchTerm: String? = nil, page: Int = 1, pageSize: Int = 100) async throws -> SpendPage {
        struct Body: Encodable {
            let searchTerm: String?
            let sortBy = "amount"
            let sortDirection = "desc"
            let page: Int
            let pageSize: Int
        }
        return try await post("teams/spend", Body(searchTerm: searchTerm, page: page, pageSize: pageSize))
    }

    /// One page of usage events between two dates (both inclusive), newest first.
    public func usageEvents(email: String?, from: Date, to: Date, page: Int, pageSize: Int = 1000) async throws -> UsageEventsPage {
        struct Body: Encodable {
            let email: String?
            let startDate: Int64
            let endDate: Int64
            let page: Int
            let pageSize: Int
        }
        let body = Body(email: email, startDate: from.epochMilliseconds, endDate: to.epochMilliseconds, page: page, pageSize: pageSize)
        return try await post("teams/filtered-usage-events", body)
    }

    /// Every usage event between two dates, following pages up to `maxPages`.
    /// `isComplete` is false when there were more pages than that.
    public func allUsageEvents(email: String?, from: Date, to: Date, maxPages: Int = 10) async throws -> (events: [UsageEvent], isComplete: Bool) {
        var events: [UsageEvent] = []
        for page in 1...maxPages {
            let result = try await usageEvents(email: email, from: from, to: to, page: page)
            events += result.events
            if !result.hasNextPage || result.events.isEmpty {
                return (events, true)
            }
        }
        return (events, false)
    }

    private func post<Response: Decodable>(_ path: String, _ body: some Encodable) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(apiKey):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transport(request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.invalidResponse }
        switch status {
        case 200..<300: break
        case 401: throw Failure.unauthorized
        case 403: throw Failure.forbidden
        case 429: throw Failure.rateLimited
        default: throw Failure.server(status: status)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Failure.invalidResponse
        }
    }
}

/// A page of `/teams/spend`.
public struct SpendPage: Decodable, Sendable {
    public let members: [MemberSpend]
    public let cycleStart: Date?
    public let totalMembers: Int?

    private enum CodingKeys: String, CodingKey {
        case teamMemberSpend, subscriptionCycleStart, totalMembers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? container.decodeIfPresent([MemberSpend].self, forKey: .teamMemberSpend)) ?? []
        cycleStart = container.lenientDouble(.subscriptionCycleStart).map(Date.init(epochMilliseconds:))
        totalMembers = container.lenientDouble(.totalMembers).map { Int($0) }
    }
}

/// One team member's spend in the current billing cycle.
public struct MemberSpend: Decodable, Sendable, Identifiable, Equatable {
    public let userID: String?
    public let name: String
    public let email: String
    public let role: String?
    /// On-demand spend, on top of what the plan includes.
    public let onDemandCents: Double
    /// Everything used this cycle, included usage plus on-demand.
    public let totalCents: Double
    /// The per-user on-demand limit Cursor enforces; nil when there is none.
    public let limitDollars: Double?

    public var id: String { userID ?? email }

    /// On-demand spend as a fraction of the limit (can go past 1).
    public var limitFraction: Double? {
        guard let limitDollars else { return nil }
        return onDemandCents / 100 / limitDollars
    }

    private enum CodingKeys: String, CodingKey {
        case userId, name, email, role, spendCents, overallSpendCents, includedSpendCents
        case effectivePerUserLimitDollars, monthlyLimitDollars, hardLimitOverrideDollars
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try? container.decodeIfPresent(String.self, forKey: .userId)
        email = (try? container.decodeIfPresent(String.self, forKey: .email)) ?? ""
        let name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.name = name.isEmpty ? email : name
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        onDemandCents = container.lenientDouble(.spendCents) ?? 0
        // The live API can send includedSpendCents instead of the documented overallSpendCents.
        totalCents = container.lenientDouble(.overallSpendCents)
            ?? onDemandCents + (container.lenientDouble(.includedSpendCents) ?? 0)
        if let effective = container.lenientDouble(.effectivePerUserLimitDollars) {
            limitDollars = effective > 0 ? effective : nil
        } else {
            limitDollars = [container.lenientDouble(.hardLimitOverrideDollars), container.lenientDouble(.monthlyLimitDollars)]
                .compactMap(\.self)
                .filter { $0 > 0 }
                .min()
        }
    }
}

/// A page of `/teams/filtered-usage-events`.
public struct UsageEventsPage: Decodable, Sendable {
    public let events: [UsageEvent]
    public let hasNextPage: Bool

    private enum CodingKeys: String, CodingKey {
        case usageEvents, pagination
    }

    private struct Pagination: Decodable {
        let hasNextPage: Bool?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? container.decodeIfPresent([UsageEvent].self, forKey: .usageEvents)) ?? []
        hasNextPage = (try? container.decodeIfPresent(Pagination.self, forKey: .pagination))?.hasNextPage ?? false
    }
}

/// One request billed to the team: which model, what it cost and how many tokens.
public struct UsageEvent: Decodable, Sendable, Equatable {
    public let date: Date?
    public let userEmail: String
    public let model: String
    public let kind: String
    public let maxMode: Bool
    /// What the request counts towards spend, included usage or not.
    public let chargedCents: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    private enum CodingKeys: String, CodingKey {
        case timestamp, userEmail, model, kind, maxMode, chargedCents, tokenUsage
    }

    private enum TokenKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = container.lenientDouble(.timestamp).map(Date.init(epochMilliseconds:))
        userEmail = (try? container.decodeIfPresent(String.self, forKey: .userEmail)) ?? ""
        let model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? ""
        self.model = model.isEmpty ? "unknown" : model
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        maxMode = (try? container.decodeIfPresent(Bool.self, forKey: .maxMode)) ?? false
        chargedCents = container.lenientDouble(.chargedCents) ?? 0

        let tokens = try? container.nestedContainer(keyedBy: TokenKeys.self, forKey: .tokenUsage)
        inputTokens = tokens?.lenientInt(.inputTokens) ?? 0
        outputTokens = tokens?.lenientInt(.outputTokens) ?? 0
        cacheReadTokens = tokens?.lenientInt(.cacheReadTokens) ?? 0
        cacheWriteTokens = tokens?.lenientInt(.cacheWriteTokens) ?? 0
    }
}

extension KeyedDecodingContainer {
    /// Cursor sends some numbers as JSON strings (epoch milliseconds, for one).
    func lenientDouble(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        lenientDouble(key).map { Int($0) }
    }
}

extension Date {
    init(epochMilliseconds: Double) {
        self.init(timeIntervalSince1970: epochMilliseconds / 1000)
    }

    var epochMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}

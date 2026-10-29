import Foundation

/// A `major.minor.patch` version; a leading "v" and any "-suffix" are ignored.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap(\.self) + Array(repeating: 0, count: 3 - parts.count)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

/// A published release on GitHub.
public struct Release: Decodable, Sendable, Equatable {
    public let version: SemanticVersion
    public let pageURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tagName)
        guard let version = SemanticVersion(tag) else {
            throw DecodingError.dataCorruptedError(forKey: .tagName, in: container, debugDescription: "Not a version: \(tag)")
        }
        self.version = version
        pageURL = try container.decode(URL.self, forKey: .htmlURL)
    }
}

/// Asks GitHub for the latest published release of Cursito (drafts and prereleases excluded).
public struct ReleaseChecker: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/OrbeApp/cursito/releases/latest")!

    private let url: URL
    private let transport: Transport

    public init(url: URL = Self.latestReleaseURL, transport: Transport? = nil) {
        self.url = url
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    /// The latest release when it's newer than `current`; nil when it isn't or nothing is published yet.
    public func newerRelease(than current: SemanticVersion) async throws -> Release? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cursito", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }

        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.version > current ? release : nil
    }
}

import Foundation
import Testing
@testable import CursitoCore

struct SemanticVersionTests {
    @Test func parsesTagsAndComparesNumerically() throws {
        #expect(SemanticVersion("v1.2.3")?.components == [1, 2, 3])
        #expect(SemanticVersion("1.2")?.description == "1.2.0")
        #expect(SemanticVersion("2.0.0-beta.1")?.components == [2, 0, 0])
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1..2") == nil)

        let v1_10 = try #require(SemanticVersion("1.10.0"))
        let v1_9 = try #require(SemanticVersion("1.9.9"))
        #expect(v1_9 < v1_10)
        #expect(SemanticVersion("v1.0") == SemanticVersion("1.0.0"))
    }
}

struct ReleaseCheckerTests {
    private static func checker(status: Int, body: String) -> ReleaseChecker {
        ReleaseChecker { request in
            #expect(request.url == ReleaseChecker.latestReleaseURL)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Cursito")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private static let latest = """
    {"tag_name": "v1.1.0", "html_url": "https://github.com/OrbeApp/cursito/releases/tag/v1.1.0", "draft": false}
    """

    @Test func returnsOnlyNewerReleases() async throws {
        let current = try #require(SemanticVersion("1.0.0"))
        let release = try await Self.checker(status: 200, body: Self.latest).newerRelease(than: current)
        #expect(release?.version.description == "1.1.0")
        #expect(release?.pageURL.absoluteString == "https://github.com/OrbeApp/cursito/releases/tag/v1.1.0")

        let upToDate = try #require(SemanticVersion("1.1.0"))
        #expect(try await Self.checker(status: 200, body: Self.latest).newerRelease(than: upToDate) == nil)
    }

    @Test func noPublishedReleaseIsNotAnError() async throws {
        let current = try #require(SemanticVersion("1.0.0"))
        #expect(try await Self.checker(status: 404, body: "{}").newerRelease(than: current) == nil)
        await #expect(throws: URLError.self) {
            try await Self.checker(status: 403, body: "{}").newerRelease(than: current)
        }
    }
}

import Foundation
import Testing
@testable import CursitoCore

struct CursorAdminAPITests {
    private static func respond(_ status: Int, _ body: String) -> CursorAdminAPI.Transport {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test func spendSendsBasicAuthAndDecodesMembers() async throws {
        let api = CursorAdminAPI(apiKey: "crsr_test") { request in
            #expect(request.url?.absoluteString == "https://api.cursor.com/teams/spend")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic Y3Jzcl90ZXN0Og==")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            #expect(body?["searchTerm"] as? String == "alex@company.com")
            #expect(body?["sortBy"] as? String == "amount")
            return try await Self.respond(200, """
            {
              "teamMemberSpend": [
                {"userId": "user_A", "spendCents": 2450.125487, "overallSpendCents": 3200.75, "name": "Alex",
                 "email": "alex@company.com", "role": "member", "hardLimitOverrideDollars": 100,
                 "monthlyLimitDollars": null, "effectivePerUserLimitDollars": 100},
                {"userId": "user_B", "spendCents": 0, "email": "sam@company.com", "effectivePerUserLimitDollars": 0}
              ],
              "subscriptionCycleStart": "1708992000000",
              "totalMembers": 15
            }
            """)(request)
        }

        let page = try await api.spend(searchTerm: "alex@company.com")

        #expect(page.cycleStart == Date(timeIntervalSince1970: 1_708_992_000))
        #expect(page.totalMembers == 15)
        #expect(page.members.map(\.id) == ["user_A", "user_B"])
        let alex = page.members[0]
        #expect(alex.totalCents == 3200.75)
        #expect(alex.limitDollars == 100)
        #expect(abs((alex.limitFraction ?? 0) - 0.245) < 0.001)
        let sam = page.members[1]
        #expect(sam.name == "sam@company.com")
        #expect(sam.totalCents == 0)
        #expect(sam.limitDollars == nil && sam.limitFraction == nil)
    }

    @Test func spendDecodesTheLiveShapeWithoutOverallOrEffectiveLimit() throws {
        let json = """
        {"teamMemberSpend": [
          {"spendCents": 428284.12, "includedSpendCents": 50090.53, "email": "a@b.c", "role": "owner",
           "monthlyLimitDollars": null, "hardLimitOverrideDollars": 0, "totalPercentUsed": 39.7},
          {"spendCents": 100, "email": "d@e.f", "monthlyLimitDollars": 200, "hardLimitOverrideDollars": 150}
        ], "subscriptionCycleStart": 1791449337000, "totalMembers": 2, "limitedUsersCount": 1}
        """
        let page = try JSONDecoder().decode(SpendPage.self, from: Data(json.utf8))

        #expect(abs(page.members[0].totalCents - 478_374.65) < 0.001)
        #expect(page.members[0].limitDollars == nil)
        #expect(page.members[1].limitDollars == 150)
    }

    @Test func usageEventsDecodeStringTimestampsAndMissingTokens() async throws {
        let api = CursorAdminAPI(apiKey: "k", transport: Self.respond(200, """
        {
          "pagination": {"numPages": 1, "currentPage": 1, "hasNextPage": false},
          "usageEvents": [
            {"timestamp": "1750979225854", "userEmail": "a@b.c", "model": "claude-4.5-sonnet", "kind": "Usage-based",
             "maxMode": true, "tokenUsage": {"inputTokens": 126, "outputTokens": 450, "cacheWriteTokens": 6112,
             "cacheReadTokens": 11964, "totalCents": 20.18}, "chargedCents": 21.36},
            {"timestamp": 1750978339901, "model": "", "kind": "Included in Business", "chargedCents": 8}
          ]
        }
        """))

        let page = try await api.usageEvents(email: "a@b.c", from: .distantPast, to: .now, page: 1)

        #expect(!page.hasNextPage)
        #expect(page.events.count == 2)
        #expect(page.events[0].date == Date(timeIntervalSince1970: 1_750_979_225.854))
        #expect(page.events[0].totalTokens == 126 + 450 + 6112 + 11964)
        #expect(page.events[1].model == "unknown")
        #expect(page.events[1].totalTokens == 0)
        #expect(page.events[1].chargedCents == 8)
    }

    @Test func allUsageEventsStopsAtTheLastPageOrTheCap() async throws {
        let page = """
        {"pagination": {"hasNextPage": true}, "usageEvents": [{"model": "m", "chargedCents": 1}]}
        """
        let capped = CursorAdminAPI(apiKey: "k", transport: Self.respond(200, page))
        let result = try await capped.allUsageEvents(email: nil, from: .distantPast, to: .now, maxPages: 3)
        #expect(result.events.count == 3)
        #expect(!result.isComplete)

        let lastPage = CursorAdminAPI(apiKey: "k", transport: Self.respond(200, page.replacingOccurrences(of: "true", with: "false")))
        let complete = try await lastPage.allUsageEvents(email: nil, from: .distantPast, to: .now, maxPages: 3)
        #expect(complete.events.count == 1)
        #expect(complete.isComplete)
    }

    @Test func httpErrorsMapToFailures() async {
        for (status, failure) in [(401, CursorAdminAPI.Failure.unauthorized), (403, .forbidden), (429, .rateLimited), (500, .server(status: 500))] {
            let api = CursorAdminAPI(apiKey: "k", transport: Self.respond(status, "{}"))
            await #expect(throws: failure) { try await api.spend() }
        }
        let garbage = CursorAdminAPI(apiKey: "k", transport: Self.respond(200, "<html>"))
        await #expect(throws: CursorAdminAPI.Failure.invalidResponse) { try await garbage.spend() }
    }
}

struct SpendForecastTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var cycleStart: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))! }
    private func day(_ offset: Double) -> Date { cycleStart.addingTimeInterval(offset * 86_400) }

    @Test func projectsTheAveragePaceToTheEndOfTheCycle() throws {
        // 10 days at $100/day in a 31-day cycle
        let forecast = try #require(SpendForecast(spentCents: 100_000, cycleStart: cycleStart, now: day(10), calendar: calendar))
        #expect(forecast.cycleEnd == day(31))
        #expect(abs(forecast.projectedCents - 310_000) < 0.01)
        #expect(forecast.capReachedAt == nil)
    }

    @Test func saysWhenThePaceReachesTheCap() throws {
        let forecast = try #require(SpendForecast(spentCents: 100_000, cycleStart: cycleStart, now: day(10), capCents: 200_000, calendar: calendar))
        #expect(forecast.capReachedAt == day(20))

        let notThisCycle = SpendForecast(spentCents: 100_000, cycleStart: cycleStart, now: day(10), capCents: 500_000, calendar: calendar)
        #expect(notThisCycle?.capReachedAt == nil)
        let alreadyPast = SpendForecast(spentCents: 100_000, cycleStart: cycleStart, now: day(10), capCents: 50_000, calendar: calendar)
        #expect(alreadyPast?.capReachedAt == nil)
    }

    @Test func waitsForEnoughOfTheCycle() {
        #expect(SpendForecast(spentCents: 10_000, cycleStart: cycleStart, now: day(1), calendar: calendar) == nil)
        #expect(SpendForecast(spentCents: 0, cycleStart: cycleStart, now: day(10), calendar: calendar) == nil)
        #expect(SpendForecast(spentCents: 10_000, cycleStart: cycleStart, now: day(40), calendar: calendar) == nil)
    }
}

struct LimitAlertTests {
    @Test func alertsAtTheThresholdAndAgainPastTheLimit() {
        #expect(LimitAlert.current(fraction: 0.79, warningPercent: 80, cycle: 1) == nil)
        #expect(LimitAlert.current(fraction: 0.8, warningPercent: 80, cycle: 1)?.percent == 80)
        #expect(LimitAlert.current(fraction: 1.03, warningPercent: 80, cycle: 1)?.percent == 100)
        #expect(LimitAlert.current(fraction: 1.5, warningPercent: 0, cycle: 1) == nil)
        #expect(LimitAlert.current(fraction: nil, warningPercent: 80, cycle: 1) == nil)
    }

    @Test func notifiesOncePerThresholdAndCycle() {
        let warned = LimitAlert(cycle: 1, percent: 80)
        #expect(warned.isNew(since: nil))
        #expect(!warned.isNew(since: warned))
        #expect(LimitAlert(cycle: 1, percent: 100).isNew(since: warned))
        #expect(!warned.isNew(since: LimitAlert(cycle: 1, percent: 100)))
        #expect(warned.isNew(since: LimitAlert(cycle: 0, percent: 100)))
        #expect(LimitAlert(stored: warned.stored) == warned)
        #expect(LimitAlert(stored: "garbage") == nil)
    }
}

struct UsageReportTests {
    private static func event(_ model: String, cents: Double, day: Int, tokens: Int = 0, conversation: String? = nil) throws -> UsageEvent {
        let milliseconds = Date(timeIntervalSince1970: 1_767_225_600 + Double(day) * 86_400 + 3_600).epochMilliseconds
        let conversationField = conversation.map { #""conversationId": "\#($0)", "# } ?? ""
        let json = """
        {\(conversationField)"timestamp": "\(milliseconds)", "model": "\(model)", "chargedCents": \(cents), "tokenUsage": {"inputTokens": \(tokens)}}
        """
        return try JSONDecoder().decode(UsageEvent.self, from: Data(json.utf8))
    }

    @Test func groupsByModelAndFillsEveryDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
        let end = start.addingTimeInterval(3 * 86_400 + 60)

        let report = UsageReport(
            events: [
                try Self.event("sonnet", cents: 10, day: 0, tokens: 100),
                try Self.event("opus", cents: 50, day: 0, tokens: 10),
                try Self.event("sonnet", cents: 15, day: 2, tokens: 200),
            ],
            from: start,
            to: end,
            calendar: calendar
        )

        #expect(report.byModel.map(\.model) == ["opus", "sonnet"])
        #expect(report.byModel[1].requests == 2)
        #expect(report.byModel[1].tokens == 300)
        #expect(report.byModel[1].chargedCents == 25)
        #expect(report.byDay.map(\.chargedCents) == [60, 0, 15, 0])
        #expect(report.byDay.map(\.requests) == [2, 0, 1, 0])
        #expect(report.requests == 3 && report.tokens == 310 && report.chargedCents == 75)
        #expect(report.bySession.isEmpty)
    }

    @Test func groupsConversationsMostExpensiveFirst() throws {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let report = UsageReport(
            events: [
                try Self.event("sonnet", cents: 10, day: 0, conversation: "a"),
                try Self.event("opus", cents: 30, day: 1, conversation: "a"),
                try Self.event("sonnet", cents: 5, day: 1, conversation: "a"),
                try Self.event("gpt", cents: 20, day: 2, conversation: "b"),
                try Self.event("tab", cents: 99, day: 2),
            ],
            from: start,
            to: start.addingTimeInterval(3 * 86_400)
        )

        #expect(report.bySession.map(\.conversationID) == ["a", "b"])
        let first = report.bySession[0]
        #expect(first.requests == 3 && first.chargedCents == 45)
        #expect(first.mainModel == "opus")
        #expect(first.started == start.addingTimeInterval(3_600))
        #expect(first.lastActivity == start.addingTimeInterval(86_400 + 3_600))
    }
}

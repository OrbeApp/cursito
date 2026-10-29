import Foundation

/// Usage events rolled up by model and by day, for the Cursor Usage window.
public struct UsageReport: Sendable, Equatable {
    public struct ModelUsage: Sendable, Equatable, Identifiable {
        public let model: String
        public let requests: Int
        public let tokens: Int
        public let chargedCents: Double

        public var id: String { model }
    }

    public struct DayUsage: Sendable, Equatable, Identifiable {
        /// Start of the day in the calendar's time zone.
        public let day: Date
        public let requests: Int
        public let chargedCents: Double

        public var id: Date { day }
    }

    /// One agent conversation, from its first request to its last.
    public struct SessionUsage: Sendable, Equatable, Identifiable {
        public let conversationID: String
        public let started: Date?
        public let lastActivity: Date?
        public let requests: Int
        public let tokens: Int
        public let chargedCents: Double
        /// The model that cost the most in this conversation.
        public let mainModel: String

        public var id: String { conversationID }
    }

    /// Most expensive first.
    public let byModel: [ModelUsage]
    /// Every day from `from` to `to`, including days without usage.
    public let byDay: [DayUsage]
    /// Most expensive first; events without a conversation are left out.
    public let bySession: [SessionUsage]
    public let requests: Int
    public let tokens: Int
    public let chargedCents: Double

    public init(events: [UsageEvent], from: Date, to: Date, calendar: Calendar = .current) {
        var models: [String: (requests: Int, tokens: Int, cents: Double)] = [:]
        var days: [Date: (requests: Int, cents: Double)] = [:]
        for event in events {
            models[event.model, default: (0, 0, 0)].requests += 1
            models[event.model]?.tokens += event.totalTokens
            models[event.model]?.cents += event.chargedCents
            if let date = event.date {
                let day = calendar.startOfDay(for: date)
                days[day, default: (0, 0)].requests += 1
                days[day]?.cents += event.chargedCents
            }
        }

        byModel = models
            .map { ModelUsage(model: $0.key, requests: $0.value.requests, tokens: $0.value.tokens, chargedCents: $0.value.cents) }
            .sorted { ($0.chargedCents, $0.requests, $1.model) > ($1.chargedCents, $1.requests, $0.model) }

        var byDay: [DayUsage] = []
        var day = calendar.startOfDay(for: min(from, to))
        let lastDay = calendar.startOfDay(for: max(from, to))
        while day <= lastDay {
            let usage = days[day] ?? (0, 0)
            byDay.append(DayUsage(day: day, requests: usage.requests, chargedCents: usage.cents))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        self.byDay = byDay

        bySession = Dictionary(grouping: events.filter { $0.conversationID != nil }) { $0.conversationID! }
            .map { conversationID, events in
                let dates = events.compactMap(\.date)
                let costByModel = Dictionary(grouping: events, by: \.model)
                    .mapValues { $0.reduce(0) { $0 + $1.chargedCents } }
                return SessionUsage(
                    conversationID: conversationID,
                    started: dates.min(),
                    lastActivity: dates.max(),
                    requests: events.count,
                    tokens: events.reduce(0) { $0 + $1.totalTokens },
                    chargedCents: events.reduce(0) { $0 + $1.chargedCents },
                    mainModel: costByModel.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "unknown"
                )
            }
            .sorted { ($0.chargedCents, $1.conversationID) > ($1.chargedCents, $0.conversationID) }

        requests = events.count
        tokens = events.reduce(0) { $0 + $1.totalTokens }
        chargedCents = events.reduce(0) { $0 + $1.chargedCents }
    }
}

import Foundation

/// Where this billing cycle's spend ends up if it keeps the average pace since
/// the cycle started.
public struct SpendForecast: Equatable, Sendable {
    /// Earlier than this the pace says little: one heavy morning would double the forecast.
    public static let minimumElapsed: TimeInterval = 2 * 86_400

    /// A month after the cycle start, as Cursor bills.
    public let cycleEnd: Date
    public let projectedCents: Double
    /// When spend reaches the cap at this pace; nil without a cap, when it's already
    /// reached, or when the cycle ends first.
    public let capReachedAt: Date?

    /// Nil before `minimumElapsed`, outside the cycle, or with nothing spent yet.
    public init?(spentCents: Double, cycleStart: Date, now: Date, capCents: Double? = nil, calendar: Calendar = .current) {
        guard let cycleEnd = calendar.date(byAdding: .month, value: 1, to: cycleStart),
              now < cycleEnd,
              now.timeIntervalSince(cycleStart) >= Self.minimumElapsed,
              spentCents > 0
        else { return nil }

        let centsPerSecond = spentCents / now.timeIntervalSince(cycleStart)
        self.cycleEnd = cycleEnd
        projectedCents = spentCents + centsPerSecond * cycleEnd.timeIntervalSince(now)
        if let capCents, capCents > spentCents {
            let reached = now.addingTimeInterval((capCents - spentCents) / centsPerSecond)
            capReachedAt = reached < cycleEnd ? reached : nil
        } else {
            capReachedAt = nil
        }
    }
}

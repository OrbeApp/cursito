import Foundation

/// When Cursito warns about the on-demand limit: once when spend reaches the
/// chosen percentage and once more past 100%, per billing cycle.
public struct LimitAlert: Equatable, Sendable {
    /// Start of the billing cycle, in epoch seconds.
    public let cycle: Int
    /// The threshold crossed: the chosen percentage, or 100 once the limit is reached.
    public let percent: Int

    public init(cycle: Int, percent: Int) {
        self.cycle = cycle
        self.percent = percent
    }

    /// The alert spend is in right now, if any. A `warningPercent` of 0 turns alerts off.
    public static func current(fraction: Double?, warningPercent: Int, cycle: Int) -> LimitAlert? {
        guard warningPercent > 0, let fraction else { return nil }
        if fraction >= 1 { return LimitAlert(cycle: cycle, percent: 100) }
        if fraction * 100 >= Double(warningPercent) { return LimitAlert(cycle: cycle, percent: warningPercent) }
        return nil
    }

    /// Whether this alert is news compared with the last one notified.
    public func isNew(since last: LimitAlert?) -> Bool {
        guard let last, last.cycle == cycle else { return true }
        return percent > last.percent
    }

    /// "cycle:percent", to keep the last alert in UserDefaults.
    public var stored: String { "\(cycle):\(percent)" }

    public init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let cycle = Int(parts[0]), let percent = Int(parts[1]) else { return nil }
        self.init(cycle: cycle, percent: percent)
    }
}

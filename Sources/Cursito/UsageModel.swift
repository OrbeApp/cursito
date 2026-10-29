import AppKit
import CursitoCore
import Observation
import SQLite3

/// Spend and usage for this billing cycle, from Cursor's Admin API.
///
/// The API key stays in the keychain and is only read for a refresh. Cursor
/// aggregates usage hourly, so the menu refreshes at most once an hour.
@MainActor
@Observable
final class UsageModel {
    private static let connectedKey = "usageConnected"
    private static let emailKey = "usageEmail"
    private static let staleAfter: TimeInterval = 60 * 60
    private static let pollInterval: Duration = .seconds(10 * 60)
    private static let warningPercentKey = "usageWarningPercent"
    private static let notifiesKey = "usageNotifiesNearLimit"
    private static let lastAlertKey = "usageLastLimitAlert"
    private static let budgetKey = "usageMonthlyBudget"

    static let warningPercentChoices = [50, 70, 80, 90, 100]

    /// What the warning measures spend against.
    enum SpendCap: Equatable {
        /// Cursor's per-user limit, against on-demand spend.
        case cursorLimit(dollars: Double)
        /// The budget set in Cursito, against everything spent this cycle.
        case budget(dollars: Double)

        var dollars: Double {
            switch self {
            case .cursorLimit(let dollars), .budget(let dollars): dollars
            }
        }

        var name: String {
            switch self {
            case .cursorLimit: "limit"
            case .budget: "budget"
            }
        }
    }

    /// Percentage of the spend cap from which Cursito warns; 0 never warns.
    var warningPercent: Int {
        didSet { UserDefaults.standard.set(warningPercent, forKey: Self.warningPercentKey) }
    }

    /// Whole dollars per billing cycle, used when Cursor sets no limit for you; 0 is none.
    private(set) var monthlyBudget: Int {
        didSet {
            UserDefaults.standard.set(monthlyBudget, forKey: Self.budgetKey)
            UserDefaults.standard.removeObject(forKey: Self.lastAlertKey)
        }
    }

    private(set) var notifiesNearLimit: Bool {
        didSet { UserDefaults.standard.set(notifiesNearLimit, forKey: Self.notifiesKey) }
    }

    private(set) var isConnected: Bool
    private(set) var email: String
    private(set) var isLoading = false
    private(set) var me: MemberSpend?
    private(set) var team: [MemberSpend] = []
    private(set) var report: UsageReport?
    private(set) var cycleStart: Date?
    /// False when there were more usage events than Cursito fetches.
    private(set) var eventsAreComplete = true
    /// Members in the team, which can be more than `team` holds.
    private(set) var teamSize = 0
    private(set) var lastUpdated: Date?
    private(set) var problem: String?

    init() {
        isConnected = UserDefaults.standard.bool(forKey: Self.connectedKey)
        email = UserDefaults.standard.string(forKey: Self.emailKey) ?? Self.cursorAccountEmail() ?? ""
        warningPercent = UserDefaults.standard.object(forKey: Self.warningPercentKey) as? Int ?? 80
        notifiesNearLimit = UserDefaults.standard.bool(forKey: Self.notifiesKey)
        monthlyBudget = UserDefaults.standard.integer(forKey: Self.budgetKey)
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfStale()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// The email Cursor is signed in with on this Mac, as a default for "me".
    var suggestedEmail: String {
        email.isEmpty ? Self.cursorAccountEmail() ?? "" : email
    }

    var topModel: UsageReport.ModelUsage? { report?.byModel.first }

    /// Cursor's per-user limit when there is one, otherwise the budget set in Cursito.
    var spendCap: SpendCap? {
        if let limit = me?.limitDollars { return .cursorLimit(dollars: limit) }
        return monthlyBudget > 0 ? .budget(dollars: Double(monthlyBudget)) : nil
    }

    /// The spend measured against the cap: on-demand for Cursor's limit, everything for a budget.
    var capSpentCents: Double? {
        guard let me, let spendCap else { return nil }
        switch spendCap {
        case .cursorLimit: return me.onDemandCents
        case .budget: return me.totalCents
        }
    }

    /// Spend as a fraction of the cap (can go past 1).
    var capFraction: Double? {
        guard let capSpentCents, let spendCap else { return nil }
        return capSpentCents / 100 / spendCap.dollars
    }

    /// Spend as a fraction of the cap, once it's close enough to warn about.
    var limitWarning: Double? {
        guard let capFraction, currentAlert != nil else { return nil }
        return capFraction
    }

    private var currentAlert: LimitAlert? {
        let cycle = Int(cycleStart?.timeIntervalSince1970 ?? 0)
        return LimitAlert.current(fraction: capFraction, warningPercent: warningPercent, cycle: cycle)
    }

    /// Asks for the monthly budget in whole dollars; an empty answer removes it.
    func editBudget() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Monthly Budget"
        alert.informativeText = "Cursito warns when this billing cycle's total Cursor spend reaches your threshold. "
            + "Whole dollars; leave it empty for no budget."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "5000"
        field.stringValue = monthlyBudget > 0 ? String(monthlyBudget) : ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        monthlyBudget = Int(field.stringValue.filter(\.isASCII).filter(\.isNumber)) ?? 0
        Task { await notifyIfNeeded() }
    }

    /// Turning notifications on asks macOS for permission first.
    func setNotifiesNearLimit(_ isOn: Bool) async {
        notifiesNearLimit = isOn ? await LimitNotifier.requestPermission() : false
        await notifyIfNeeded()
    }

    /// Posts a notification the first time spend crosses the threshold, and again
    /// past the cap, in each billing cycle.
    private func notifyIfNeeded() async {
        guard notifiesNearLimit, let spendCap, let spent = capSpentCents, let fraction = capFraction,
              let alert = currentAlert
        else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastAlertKey).flatMap(LimitAlert.init(stored:))
        guard alert.isNew(since: last) else { return }

        let percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(.ui))
        let title = alert.percent >= 100
            ? "You've reached your Cursor spend \(spendCap.name)"
            : "Cursor spend at \(percent) of your \(spendCap.name)"
        let spentText = switch spendCap {
        case .cursorLimit: "On-demand \(spent.centsText)"
        case .budget: spent.centsText
        }
        let body = "\(spentText) of \((spendCap.dollars * 100).centsText) this billing cycle."
        await LimitNotifier.post(title: title, body: body)
        UserDefaults.standard.set(alert.stored, forKey: Self.lastAlertKey)
    }

    var teamTotalCents: Double { team.reduce(0) { $0 + $1.totalCents } }

    func refreshIfStale() async {
        guard isConnected else { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.staleAfter { return }
        await refresh()
    }

    func refresh() async {
        guard isConnected, !isLoading else { return }
        guard let apiKey = KeychainItem.cursorAdminAPIKey.read() else {
            problem = "Cursito couldn't read the API key from the keychain. Connect it again."
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let api = CursorAdminAPI(apiKey: apiKey)
            let me = try await Self.member(email, in: api)
            let teamPage = try await api.spend()
            let now = Date()
            let from = teamPage.cycleStart ?? Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            let usage = try await api.allUsageEvents(email: email, from: from, to: now)

            self.me = me
            team = teamPage.members.sorted { $0.totalCents > $1.totalCents }
            cycleStart = teamPage.cycleStart
            report = UsageReport(events: usage.events, from: from, to: now)
            eventsAreComplete = usage.isComplete
            teamSize = max(teamPage.totalMembers ?? 0, teamPage.members.count)
            lastUpdated = now
            problem = nil
            await notifyIfNeeded()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Checks the key and the email against the API before keeping them.
    /// Returns an error message when they don't work.
    func connect(apiKey: String, email: String) async -> String? {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !email.isEmpty else { return "Enter the API key and your email." }

        do {
            _ = try await Self.member(email, in: CursorAdminAPI(apiKey: apiKey))
            try KeychainItem.cursorAdminAPIKey.save(apiKey)
        } catch {
            return error.localizedDescription
        }

        self.email = email
        isConnected = true
        UserDefaults.standard.set(email, forKey: Self.emailKey)
        UserDefaults.standard.set(true, forKey: Self.connectedKey)
        lastUpdated = nil
        await refresh()
        return nil
    }

    /// Changes whose usage the window shows, keeping the stored key.
    func changeEmail(to email: String) async -> String? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = KeychainItem.cursorAdminAPIKey.read() else { return "Connect the API key again." }
        return await connect(apiKey: apiKey, email: email)
    }

    func disconnect() {
        KeychainItem.cursorAdminAPIKey.delete()
        UserDefaults.standard.removeObject(forKey: Self.connectedKey)
        isConnected = false
        me = nil
        team = []
        report = nil
        cycleStart = nil
        lastUpdated = nil
        problem = nil
    }

    private static func member(_ email: String, in api: CursorAdminAPI) async throws -> MemberSpend {
        let page = try await api.spend(searchTerm: email, pageSize: 20)
        guard let member = page.members.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw UsageError.notInTeam(email)
        }
        return member
    }

    /// Reads `cursorAuth/cachedEmail` from Cursor's state database, read-only.
    private static func cursorAccountEmail() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else { return nil }
        let email = String(cString: text)
        return email.contains("@") ? email : nil
    }
}

enum UsageError: LocalizedError {
    case notInTeam(String)

    var errorDescription: String? {
        switch self {
        case .notInTeam(let email): "\(email) isn't a member of the team this key belongs to."
        }
    }
}

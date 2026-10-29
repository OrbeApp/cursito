import Charts
import CursitoCore
import SwiftUI

/// Spend and usage for this billing cycle: by model, by day and across the team.
struct UsageView: View {
    let usage: UsageModel
    @State private var tab = Tab.models
    @State private var isEditingSettings = false

    enum Tab: String, CaseIterable, Identifiable {
        case models = "Models"
        case days = "Days"
        case sessions = "Sessions"
        case team = "Team"

        var id: Self { self }
    }

    var body: some View {
        Group {
            if usage.isConnected {
                connected
            } else {
                UsageSettingsForm(usage: usage)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 460)
        .task { await usage.refreshIfStale() }
    }

    private var connected: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Cursor usage", systemImage: "chart.bar.xaxis").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            if let problem = usage.problem, usage.report != nil {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 12)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Settings…") { isEditingSettings = true }
                Spacer()
                if usage.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") {
                    Task { await usage.refresh() }
                }
                .disabled(usage.isLoading)
            }
            .padding()
        }
        .sheet(isPresented: $isEditingSettings) {
            UsageSettingsForm(usage: usage) { isEditingSettings = false }
                .frame(width: 460)
        }
    }

    private var subtitle: String {
        var parts = [usage.email]
        if let cycleStart = usage.cycleStart {
            parts.append("Billing cycle since \(cycleStart.dayText)")
        }
        if let forecast = usage.forecast {
            parts.append("on pace for ~\(forecast.projectedCents.wholeDollarsText) by \(forecast.cycleEnd.dayText)")
        }
        if let lastUpdated = usage.lastUpdated {
            parts.append("Updated \(lastUpdated.relativeText)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let report = usage.report {
            switch tab {
            case .models: ModelsTab(report: report, isComplete: usage.eventsAreComplete)
            case .days: DaysTab(report: report)
            case .sessions: SessionsTab(report: report)
            case .team: TeamTab(usage: usage)
            }
        } else if usage.isLoading {
            ProgressView("Loading usage…")
        } else if let problem = usage.problem {
            ContentUnavailableView("Couldn't load usage", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else {
            ContentUnavailableView("No data yet", systemImage: "chart.bar.xaxis", description: Text("Refresh to load this cycle's usage."))
        }
    }
}

private struct ModelsTab: View {
    let report: UsageReport
    let isComplete: Bool

    var body: some View {
        VStack(spacing: 0) {
            Table(report.byModel) {
                TableColumn("Model", value: \.model)
                TableColumn("Requests") { Text($0.requests, format: .number) }
                    .width(80)
                TableColumn("Tokens") { Text($0.tokens.compactText) }
                    .width(80)
                TableColumn("Cost") { Text($0.chargedCents.centsText) }
                    .width(90)
            }
            HStack {
                Text("\(report.requests.formatted()) requests · \(report.tokens.compactText) tokens · \(report.chargedCents.centsText)")
                Spacer()
                if !isComplete {
                    Text("Only the latest 10,000 requests")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

private struct DaysTab: View {
    let report: UsageReport

    var body: some View {
        Chart(report.byDay) { day in
            BarMark(
                x: .value("Day", day.day, unit: .day),
                y: .value("Cost", day.chargedCents / 100)
            )
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text((dollars * 100).centsText)
                    }
                }
            }
        }
        .environment(\.locale, .ui)
        .padding()
    }
}

private struct SessionsTab: View {
    private static let shown = 100

    let report: UsageReport

    var body: some View {
        VStack(spacing: 0) {
            Table(Array(report.bySession.prefix(Self.shown))) {
                TableColumn("Started") { session in
                    Text(session.started?.shortText ?? "—")
                        .help(session.lastActivity.map { "Last request \($0.longText)" } ?? "")
                }
                .width(min: 130, ideal: 150)
                TableColumn("Main model") { Text($0.mainModel).help($0.mainModel) }
                TableColumn("Requests") { Text($0.requests, format: .number) }
                    .width(70)
                TableColumn("Tokens") { Text($0.tokens.compactText) }
                    .width(70)
                TableColumn("Cost") { Text($0.chargedCents.centsText) }
                    .width(80)
            }
            .contextMenu(forSelectionType: UsageReport.SessionUsage.ID.self) { ids in
                if let id = ids.first {
                    Button("Copy Conversation ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    }
                }
            }
            HStack {
                Text(summary)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var summary: String {
        let sessions = report.bySession
        let inSessions = sessions.reduce(0) { $0 + $1.chargedCents }
        var parts = ["\(sessions.count) conversations · \(inSessions.centsText)"]
        if sessions.count > Self.shown {
            parts.append("showing the \(Self.shown) most expensive")
        }
        let outside = report.chargedCents - inSessions
        if outside >= 1 {
            parts.append("\(outside.centsText) outside conversations (Tab, Cmd+K…)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct TeamTab: View {
    let usage: UsageModel

    var body: some View {
        VStack(spacing: 0) {
            Table(usage.team) {
                TableColumn("Member") { member in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.id == usage.me?.id ? "\(member.name) (you)" : member.name)
                        Text(member.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TableColumn("On-demand") { Text($0.onDemandCents.centsText) }
                    .width(90)
                TableColumn("Limit") { member in
                    Text(member.limitDollars.map { ($0 * 100).centsText } ?? "None")
                        .foregroundStyle(member.limitDollars == nil ? .secondary : .primary)
                }
                .width(80)
                TableColumn("Total") { Text($0.totalCents.centsText) }
                    .width(90)
            }
            HStack {
                Text("\(usage.teamSize) members · \(usage.teamTotalCents.centsText) this cycle")
                Spacer()
                if usage.teamSize > usage.team.count {
                    Text("Showing the top \(usage.team.count) by spend")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

/// Connects an Admin API key, or changes the email and disconnects.
struct UsageSettingsForm: View {
    let usage: UsageModel
    var onClose: (() -> Void)?

    @State private var apiKey = ""
    @State private var email = ""
    @State private var error: String?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField(
                        "Admin API key",
                        text: $apiKey,
                        prompt: Text(usage.isConnected ? "Saved in the keychain" : "crsr_…")
                    )
                    TextField("Your email", text: $email, prompt: Text("you@company.com"))
                } header: {
                    Label("Connect Cursor's Admin API", systemImage: "chart.bar.xaxis")
                        .font(.headline)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cursor's Admin API is available to Enterprise teams. A team admin creates the key in the Cursor dashboard, under API Keys.")
                            .foregroundStyle(.secondary)
                        Link("Open the Cursor dashboard", destination: URL(string: "https://cursor.com/dashboard")!)
                        Text("The key is stored in your macOS keychain. It has admin rights over the team; Cursito only uses it to read spend and usage.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            HStack {
                if usage.isConnected {
                    Button("Disconnect", role: .destructive) {
                        usage.disconnect()
                        onClose?()
                    }
                }
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                }
                if let onClose {
                    Button("Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                Button(usage.isConnected ? "Save" : "Connect") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isChecking || email.isEmpty || (!usage.isConnected && apiKey.isEmpty))
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear { email = usage.suggestedEmail }
    }

    private func save() async {
        isChecking = true
        error = nil
        if usage.isConnected && apiKey.isEmpty {
            error = await usage.changeEmail(to: email)
        } else {
            error = await usage.connect(apiKey: apiKey, email: email)
        }
        isChecking = false
        if error == nil {
            apiKey = ""
            onClose?()
        }
    }
}

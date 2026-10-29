import CursitoCore
import SwiftUI

struct MenuContent: View {
    let model: SyncModel
    let usage: UsageModel
    let repos: ReposModel
    let handoff: Handoff
    let updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarLabel.showsSpendKey) private var showsSpendInMenuBar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cursito").font(.headline)
                Spacer()
                if let release = updates.available {
                    Button {
                        updates.openReleasePage()
                    } label: {
                        Label("Update to \(release.version.description)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Open the release page on GitHub")
                }
            }
            handoffButtons
            Divider()
            cursorSection
            Divider()
            usageSection
            Divider()
            reposSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task { await model.refresh() }
        .onAppear { model.isMenuOpen = true }
        .onDisappear { model.isMenuOpen = false }
    }

    private func sectionHeader(_ title: String, systemImage: String, activity: String?) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let activity {
                ProgressView().controlSize(.small)
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var handoffButtons: some View {
        HStack(spacing: 8) {
            Button {
                Task { await handoff.leave() }
            } label: {
                Label("Heading Out", systemImage: "figure.walk.departure")
                    .frame(maxWidth: .infinity)
            }
            .help("Export this Mac's Cursor setup and check every repo for work that isn't pushed")
            Button {
                Task { await handoff.arrive() }
            } label: {
                Label("Just Arrived", systemImage: "figure.walk.arrival")
                    .frame(maxWidth: .infinity)
            }
            .help("Import the other Mac's Cursor setup if there's a new one, then pull every repo")
        }
        .buttonStyle(.bordered)
        .disabled(handoff.isRunning || model.isBusy || repos.isRunning)
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Cursor Setup",
                systemImage: "cursorarrow.rays",
                activity: model.isBusy ? model.activity.label : nil
            )
            Text("MCP servers, settings, plugins, skills and extensions, from one Mac to the other.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            exportCard
            actions
            if let outcome = model.outcome {
                outcomeRow(outcome)
            }
            folderRow(
                model.syncFolderDisplay,
                reveal: model.revealSyncFolder,
                change: model.chooseSyncFolder,
                isDisabled: model.isBusy
            )
            HStack {
                Menu("Restore…") {
                    if !model.backups.isEmpty {
                        Section("Before an import on this Mac") {
                            ForEach(model.backups) { backup in
                                Button(backup.date.shortText) {
                                    Task { await model.restore(backup) }
                                }
                            }
                        }
                    }
                    if !model.previousExports.isEmpty {
                        Section("Previous exports") {
                            ForEach(model.previousExports) { export in
                                Button("\(export.host) · \(export.date.shortText)") {
                                    Task { await model.importPrevious(export) }
                                }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .disabled((model.backups.isEmpty && model.previousExports.isEmpty) || model.isBusy)
                .help(model.backups.isEmpty && model.previousExports.isEmpty
                    ? "Backups appear here after your first import, and replaced exports after your next export"
                    : "Undo an import, or import an export that a newer one replaced")
                Spacer(minLength: 4)
                Button {
                    model.editEncryption()
                } label: {
                    Label(
                        model.encryptsExports ? "Encrypted" : "Encrypt Exports…",
                        systemImage: model.encryptsExports ? "lock.fill" : "lock.open"
                    )
                }
                .buttonStyle(.link)
                .disabled(model.isBusy)
                .help(model.encryptsExports
                    ? "Exports from this Mac are encrypted with your passphrase. Click to change it or turn it off."
                    : "Encrypt exports with a passphrase, so only your Macs can read them")
            }
            .font(.caption)
        }
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info = model.info {
                Label(info.isFromThisMac ? "Exported from this Mac" : info.host, systemImage: "desktopcomputer")
                    .font(.subheadline.weight(.medium))
                Text(exportedLine(info))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(info.exportedAt.longText)
                if info.isPendingImport {
                    Label("Not imported on this Mac yet", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            } else if let problem = model.infoProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No export yet").font(.subheadline.weight(.medium))
                Text("Export this Mac's Cursor setup, then import it on the other one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let changes = model.localChanges, !changes.isEmpty {
                Label("Changed here: \(changes.summary())", systemImage: "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(localChangesHelp(changes))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        let canImport = model.info.map { !$0.isFromThisMac } ?? false
        let isPending = model.info?.isPendingImport ?? false

        return VStack(spacing: 8) {
            Button {
                Task { await model.exportThisMac() }
            } label: {
                Label("Export This Mac", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .prominentButton(!isPending)

            HStack(spacing: 8) {
                Button {
                    show(WindowID.changes)
                } label: {
                    Label("Review…", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.info == nil)

                Button {
                    Task { await model.importLatest() }
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .prominentButton(isPending)
                .disabled(!canImport)
            }
        }
        .controlSize(.large)
        .disabled(model.isBusy)
    }

    private func outcomeRow(_ outcome: SyncModel.Outcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: outcome.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(outcome.failed ? Color.orange : Color.green)
            Text(outcome.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Log") { show(WindowID.log) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Cursor Usage",
                systemImage: "chart.bar.xaxis",
                activity: usage.isLoading ? "Loading…" : nil
            )

            if !usage.isConnected {
                Text("What you've spent this billing cycle, by model, day and conversation. Needs an Admin API key from an Enterprise team.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    show(WindowID.usage)
                } label: {
                    Label("Connect Admin API Key…", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                if let me = usage.me {
                    usageCard(me)
                }
                usageStatusRow
                HStack {
                    Toggle("Show spend in the menu bar", isOn: $showsSpendInMenuBar)
                        .toggleStyle(.checkbox)
                    Spacer(minLength: 4)
                    if usage.me != nil {
                        limitWarningMenu
                    }
                }
                .font(.caption)
            }
        }
        .task { await usage.refreshIfStale() }
    }

    private var limitWarningMenu: some View {
        let cap = usage.spendCap
        let title = if cap == nil {
            "Set a Budget"
        } else if usage.warningPercent == 0 {
            "No warning"
        } else {
            "Warn at \(usage.warningPercent)%"
        }

        return Menu(title) {
            Picker("Warn at", selection: Binding(
                get: { usage.warningPercent },
                set: { usage.warningPercent = $0 }
            )) {
                ForEach(UsageModel.warningPercentChoices, id: \.self) { percent in
                    Text("\(percent)% of my \(cap?.name ?? "budget")").tag(percent)
                }
                Text("Never").tag(0)
            }
            .pickerStyle(.inline)
            .disabled(cap == nil)
            Toggle("Send a Notification", isOn: Binding(
                get: { usage.notifiesNearLimit },
                set: { isOn in Task { await usage.setNotifiesNearLimit(isOn) } }
            ))
            .disabled(cap == nil || usage.warningPercent == 0)
            Divider()
            if case .cursorLimit(let dollars) = cap {
                Text("Using your Cursor limit of \((dollars * 100).centsText)")
            } else {
                Button(usage.monthlyBudget > 0
                    ? "Monthly Budget: \((Double(usage.monthlyBudget) * 100).centsText)…"
                    : "Set Monthly Budget…"
                ) {
                    usage.editBudget()
                }
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("When the menu bar icon warns that your spend is close to your limit or budget")
    }

    private func usageCard(_ me: MemberSpend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(me.totalCents.centsText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("this cycle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let cycleStart = usage.cycleStart {
                    Text("since \(cycleStart.dayText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = usage.capFraction, let cap = usage.spendCap {
                ProgressView(value: min(fraction, 1))
                    .tint(usage.limitWarning != nil ? Color.orange : Color.accentColor)
                Text(capLine(me, cap: cap, fraction: fraction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("On-demand \(me.onDemandCents.centsText) · no limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let forecast = usage.forecast {
                Text("On pace for ~\(forecast.projectedCents.wholeDollarsText) by \(forecast.cycleEnd.dayText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This cycle's average spend per day, carried to the end of the cycle")
            }
            if let reachedAt = usage.capReachedAt, let cap = usage.spendCap {
                Label("Reaches your \(cap.name) around \(reachedAt.dayText)", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let top = usage.topModel {
                Text("Top model: \(top.model) · \(top.chargedCents.centsText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func capLine(_ me: MemberSpend, cap: UsageModel.SpendCap, fraction: Double) -> String {
        let capText = (cap.dollars * 100).centsText
        switch cap {
        case .cursorLimit:
            return "On-demand \(me.onDemandCents.centsText) of \(capText) limit"
        case .budget:
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(.ui))
            return "\(percent) of \(capText) budget · on-demand \(me.onDemandCents.centsText)"
        }
    }

    private var usageStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let problem = usage.problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(problem)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lastUpdated = usage.lastUpdated {
                Text("Updated \(lastUpdated.relativeText)")
                    .foregroundStyle(.secondary)
                    .help("Cursor aggregates usage hourly, so Cursito refreshes at most once an hour.")
            }
            Spacer(minLength: 4)
            Button {
                Task { await usage.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(usage.isLoading)
            .help("Refresh now")
            Button("Details") { show(WindowID.usage) }
                .buttonStyle(.link)
        }
        .font(.caption)
    }

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Git Repos",
                systemImage: "arrow.triangle.branch",
                activity: repos.isRunning ? "Updating…" : nil
            )

            if let folder = repos.folder {
                HStack(spacing: 8) {
                    Button {
                        Task { await repos.update(fetchOnly: false) }
                    } label: {
                        Label("Pull All", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        Task { await repos.update(fetchOnly: true) }
                    } label: {
                        Label("Fetch Only", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(repos.isRunning)

                if let lastRunAt = repos.lastRunAt {
                    let failed = repos.problem != nil || !repos.needingAttention.isEmpty
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? Color.orange : Color.green)
                        Text(repos.summary)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(lastRunAt.longText)
                        Spacer(minLength: 4)
                        Button("Details") { show(WindowID.repos) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }

                folderRow(
                    repos.folderDisplay,
                    reveal: { NSWorkspace.shared.activateFileViewerSelecting([folder]) },
                    change: repos.chooseFolder,
                    isDisabled: repos.isRunning
                )
                autoFetchMenu
            } else {
                Text("Pull every git repo in a folder at once. Never merges or rebases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    repos.chooseFolder()
                } label: {
                    Label("Choose Repos Folder…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var autoFetchMenu: some View {
        let minutes = repos.autoFetchMinutes
        return Menu {
            Picker("Fetch in the background", selection: Binding(
                get: { repos.autoFetchMinutes },
                set: { repos.autoFetchMinutes = $0 }
            )) {
                ForEach(ReposModel.autoFetchChoices, id: \.self) { choice in
                    Text("Every \(ReposModel.intervalText(minutes: choice))").tag(choice)
                }
                Text("Never").tag(0)
            }
            .pickerStyle(.inline)
            Toggle("Notify About New Commits", isOn: Binding(
                get: { repos.notifiesWhenBehind },
                set: { isOn in Task { await repos.setNotifiesWhenBehind(isOn) } }
            ))
            .disabled(minutes == 0)
        } label: {
            Label(
                minutes == 0 ? "Fetch in the Background…" : "Fetching every \(ReposModel.intervalText(minutes: minutes))",
                systemImage: "clock.arrow.circlepath"
            )
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .font(.caption)
        .help("Fetch every repo now and then, without touching working trees, and tell you when one has new commits")
    }

    private func folderRow(
        _ path: String,
        reveal: @escaping () -> Void,
        change: @escaping () -> Void,
        isDisabled: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Button(path, action: reveal)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Show in Finder")
            Spacer(minLength: 4)
            Button("Change…", action: change)
                .buttonStyle(.link)
                .disabled(isDisabled)
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Toggle("Open at Login", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            Spacer()
            Button("About") { AboutPanel.show() }
                .buttonStyle(.link)
            Button("Quit Cursito") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .keyboardShortcut("q")
        }
        .font(.caption)
    }

    private func exportedLine(_ info: ExportInfo) -> String {
        var parts = [info.exportedAt.relativeText]
        if !info.cursorVersion.isEmpty {
            parts.append("Cursor \(info.cursorVersion)")
        }
        if info.isEncrypted {
            parts.append("encrypted")
        }
        return parts.joined(separator: " · ")
    }

    private func localChangesHelp(_ changes: LocalChanges) -> String {
        var text = "Changed since this Mac's last \(changes.lastSync.rawValue) (\(changes.lastSyncAt.shortText)): "
            + changes.summary(listing: .max) + ". Export to take them to the other Mac."
        if model.info?.isPendingImport == true {
            text += " The other Mac's export is waiting too: importing it replaces these changes, exporting replaces it."
        }
        return text
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

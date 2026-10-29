import CursitoCore
import SwiftUI

struct MenuContent: View {
    let model: SyncModel
    let repos: ReposModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cursito").font(.headline)
            Divider()
            cursorSection
            Divider()
            reposSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task { await model.refresh() }
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
            Menu("Restore Backup…") {
                ForEach(model.backups) { backup in
                    Button(backup.date.shortText) {
                        Task { await model.restore(backup) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .font(.caption)
            .disabled(model.backups.isEmpty || model.isBusy)
            .help(model.backups.isEmpty ? "Backups appear here after your first import" : "Undo an import")
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
            Button("Quit Cursito") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .keyboardShortcut("q")
        }
        .font(.caption)
    }

    private func exportedLine(_ info: ExportInfo) -> String {
        let when = info.exportedAt.relativeText
        return info.cursorVersion.isEmpty ? when : "\(when) · Cursor \(info.cursorVersion)"
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

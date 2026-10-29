import CursitoCore
import SwiftUI

/// Result of the last `update-repos.sh` run, one row per repo.
struct ReposView: View {
    let repos: ReposModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Git repos").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Fetch Only") {
                    Task { await repos.update(fetchOnly: true) }
                }
                Button("Pull All") {
                    Task { await repos.update(fetchOnly: false) }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(repos.folder == nil || repos.isRunning)
            .padding()
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var subtitle: String {
        guard repos.folder != nil else { return "No folder chosen" }
        guard let lastRunAt = repos.lastRunAt else { return repos.folderDisplay }
        let action = repos.lastRunWasFetchOnly ? "Fetched" : "Pulled"
        return "\(repos.folderDisplay) · \(action) \(lastRunAt.relativeText)"
    }

    @ViewBuilder
    private var content: some View {
        if repos.isRunning && repos.repos.isEmpty {
            ProgressView("Updating…")
        } else if let problem = repos.problem {
            ContentUnavailableView("Couldn't update", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if repos.repos.isEmpty {
            ContentUnavailableView(
                "Not run yet",
                systemImage: "arrow.triangle.branch",
                description: Text("Pull All fetches every repo and fast-forwards the ones that are behind.")
            )
        } else {
            List(repos.sortedRepos) { repo in
                RepoRow(repo: repo, url: repos.folder?.appending(path: repo.name))
            }
        }
    }
}

private struct RepoRow: View {
    let repo: RepoStatus
    let url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(repo.name)
                Spacer()
                if repo.uncommittedChanges > 0, repo.state != .dirty {
                    Label("\(repo.uncommittedChanges)", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("\(repo.uncommittedChanges) uncommitted change(s)")
                }
                Text(repo.detail)
                    .font(.caption)
                    .foregroundStyle(repo.state.needsAttention ? color : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(repo.detail)
            }
            ForEach(Array(repo.log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let url {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open in Terminal") { open(url, withAppAt: "/System/Applications/Utilities/Terminal.app") }
                if let cursor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CursorApp.bundleIdentifier) {
                    Button("Open in Cursor") { open(url, withAppAt: cursor.path) }
                }
            }
        }
    }

    private func open(_ url: URL, withAppAt appPath: String) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: appPath),
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    private var symbol: String {
        switch repo.state {
        case .ok: "checkmark.circle"
        case .pulled: "arrow.down.circle.fill"
        case .ahead: "arrow.up.circle.fill"
        case .behind: "arrow.down.circle"
        case .dirty: "pencil.circle.fill"
        case .diverged: "arrow.triangle.branch"
        case .skip: "minus.circle"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch repo.state {
        case .ok, .skip: .secondary
        case .pulled: .green
        case .ahead, .behind: .blue
        case .dirty, .diverged: .orange
        case .error: .red
        }
    }
}

import AppKit
import CursitoCore
import Observation

/// "Heading Out" and "Just Arrived": the steps you'd otherwise run one by one when switching Macs.
@MainActor
@Observable
final class Handoff {
    private static let maxListedRepos = 12

    private(set) var isRunning = false

    private let sync: SyncModel
    private let repos: ReposModel

    init(sync: SyncModel, repos: ReposModel) {
        self.sync = sync
        self.repos = repos
    }

    /// Fetches the repos, exports this Mac and lists the work that only lives here.
    func leave() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        if repos.folder != nil {
            await repos.update(fetchOnly: true)
        }
        guard await sync.exportThisMac(notify: false) else {
            if let outcome = sync.outcome, outcome.failed {
                show("Couldn't export this Mac", outcome.message)
            }
            return
        }

        var message = sync.encryptsExports ? "Cursor setup exported, encrypted." : "Cursor setup exported."
        let leftovers = repos.repos.compactMap { repo in repo.workLeftBehind.map { "\(repo.name): \($0)" } }
        if repos.folder == nil {
            show("Ready to go", message)
        } else if let problem = repos.problem {
            show("Before you go…", message + "\n\nCouldn't check the git repos: \(problem)")
        } else if leftovers.isEmpty {
            show("Ready to go", message + " Every repo in \(repos.folderDisplay) is committed and pushed.")
        } else {
            message += "\n\nThis work only lives on this Mac:\n" + Self.bulletList(leftovers)
            show("Before you go…", message)
        }
    }

    /// Imports the other Mac's setup if there's a new one, then pulls every repo.
    func arrive() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        await sync.refresh()
        var paragraphs: [String] = []
        if let info = sync.info, info.isPendingImport {
            if await sync.importLatest(notify: false) {
                paragraphs.append("Imported the Cursor setup from \(info.host).")
            } else if let outcome = sync.outcome, outcome.failed {
                paragraphs.append("Couldn't import the Cursor setup: \(outcome.message)")
            } else {
                paragraphs.append("Skipped the Cursor setup from \(info.host).")
            }
        } else {
            paragraphs.append(sync.info == nil
                ? "There's no Cursor setup to import yet."
                : "This Mac already has the latest Cursor setup.")
        }

        if repos.folder != nil {
            await repos.update(fetchOnly: false)
            if let problem = repos.problem {
                paragraphs.append("Couldn't update the git repos: \(problem)")
            } else {
                paragraphs.append("Git repos: \(repos.summary).")
                let attention = repos.needingAttention.map { "\($0.name): \($0.detail)" }
                if !attention.isEmpty {
                    paragraphs.append("Left alone, sort them out by hand:\n" + Self.bulletList(attention))
                }
            }
        }
        show("Welcome back", paragraphs.joined(separator: "\n\n"))
    }

    private func show(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private static func bulletList(_ lines: [String]) -> String {
        var shown = lines.prefix(maxListedRepos).map { "• \($0)" }
        if lines.count > maxListedRepos {
            shown.append("… and \(lines.count - maxListedRepos) more")
        }
        return shown.joined(separator: "\n")
    }
}

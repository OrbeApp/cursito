import AppKit
import CursitoCore
import Observation

/// Pulls every git repo in a folder with `update-repos.sh`, independently of the Cursor sync.
@MainActor
@Observable
final class ReposModel {
    private static let folderKey = "reposFolder"

    private(set) var isRunning = false
    private(set) var repos: [RepoStatus] = []
    private(set) var lastRunAt: Date?
    private(set) var lastRunWasFetchOnly = false
    private(set) var problem: String?

    var folder: URL? {
        didSet {
            UserDefaults.standard.set(folder, forKey: Self.folderKey)
            repos = []
            lastRunAt = nil
            problem = nil
        }
    }

    private let script = ScriptRunner(scriptURL: BundledScript.url(named: "update-repos"))

    init() {
        folder = UserDefaults.standard.url(forKey: Self.folderKey)
    }

    var folderDisplay: String {
        guard let folder else { return "" }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    var needingAttention: [RepoStatus] { repos.filter(\.state.needsAttention) }

    /// "2 pulled · 1 needs attention · 12 up to date"
    var summary: String {
        if let problem { return problem }
        let pulled = repos.filter { $0.state == .pulled }.count
        let behind = repos.filter { $0.state == .behind }.count
        let attention = needingAttention.count
        let upToDate = repos.filter { $0.state == .ok }.count
        let parts = [
            pulled > 0 ? "\(pulled) pulled" : nil,
            behind > 0 ? "\(behind) behind" : nil,
            attention > 0 ? "\(attention) need\(attention == 1 ? "s" : "") attention" : nil,
            upToDate > 0 ? "\(upToDate) up to date" : nil,
        ].compactMap(\.self)
        return parts.isEmpty ? "\(repos.count) repos checked" : parts.joined(separator: " · ")
    }

    /// Repos that need attention first, then the ones that changed, then the rest.
    var sortedRepos: [RepoStatus] {
        func rank(_ state: RepoStatus.State) -> Int {
            if state.needsAttention { return 0 }
            switch state {
            case .pulled, .behind, .ahead: return 1
            default: return 2
            }
        }
        return repos.enumerated()
            .sorted { (rank($0.element.state), $0.offset) < (rank($1.element.state), $1.offset) }
            .map(\.element)
    }

    func update(fetchOnly: Bool) async {
        guard let folder, !isRunning else { return }
        isRunning = true
        let result = await script.run(["-C", folder.path, "-p"] + (fetchOnly ? ["-f"] : []))
        isRunning = false

        repos = Porcelain.repos(in: result.output)
        lastRunAt = Date()
        lastRunWasFetchOnly = fetchOnly
        // Exit 1 with results just means some repos need attention
        problem = repos.isEmpty ? Porcelain.errorMessage(in: result.output) : nil
    }

    func chooseFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder ?? FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that holds your git repos (one level deep)."
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }
}

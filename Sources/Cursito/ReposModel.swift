import AppKit
import CursitoCore
import Observation

/// Pulls every git repo in a folder with `update-repos.sh`, independently of the Cursor sync.
@MainActor
@Observable
final class ReposModel {
    static let autoFetchChoices = [15, 30, 60]
    private static let folderKey = "reposFolder"
    private static let autoFetchKey = "reposAutoFetchMinutes"
    private static let notifiesKey = "reposNotifyBehind"
    private static let autoFetchCheckInterval: Duration = .seconds(60)

    private(set) var isRunning = false
    private(set) var repos: [RepoStatus] = []
    private(set) var lastRunAt: Date?
    private(set) var lastRunWasFetchOnly = false
    private(set) var problem: String?
    /// Minutes between background fetches; 0 turns them off.
    var autoFetchMinutes: Int {
        didSet { UserDefaults.standard.set(autoFetchMinutes, forKey: Self.autoFetchKey) }
    }
    private(set) var notifiesWhenBehind: Bool {
        didSet { UserDefaults.standard.set(notifiesWhenBehind, forKey: Self.notifiesKey) }
    }
    /// Includes failed background fetches, so being offline doesn't retry every minute.
    private var lastAttemptAt: Date?
    /// Repos already notified as behind; one stays here until it catches up.
    private var notifiedBehind: Set<String> = []

    var folder: URL? {
        didSet {
            UserDefaults.standard.set(folder, forKey: Self.folderKey)
            repos = []
            lastRunAt = nil
            problem = nil
            notifiedBehind = []
        }
    }

    private let script = ScriptRunner(scriptURL: BundledScript.url(named: "update-repos"))

    init() {
        folder = UserDefaults.standard.url(forKey: Self.folderKey)
        autoFetchMinutes = UserDefaults.standard.integer(forKey: Self.autoFetchKey)
        notifiesWhenBehind = UserDefaults.standard.object(forKey: Self.notifiesKey) as? Bool ?? true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoFetchCheckInterval)
                await self?.fetchInBackgroundIfDue()
            }
        }
    }

    static func intervalText(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes == 60 ? "hour" : "\(minutes / 60) hours"
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
        await run(fetchOnly: fetchOnly, inBackground: false)
    }

    func setNotifiesWhenBehind(_ isOn: Bool) async {
        notifiesWhenBehind = isOn ? await Notifier.requestPermission() : false
    }

    /// Runs `update-repos.sh`. A background run that couldn't fetch a single repo (offline,
    /// usually) keeps the previous results instead of listing every repo as failed.
    private func run(fetchOnly: Bool, inBackground: Bool) async {
        guard let folder, !isRunning else { return }
        isRunning = true
        lastAttemptAt = Date()
        let result = await script.run(["-C", folder.path, "-p"] + (fetchOnly ? ["-f"] : []))
        isRunning = false

        let found = Porcelain.repos(in: result.output)
        if inBackground, found.isEmpty || found.allSatisfy({ $0.state == .error }) {
            return
        }
        repos = found
        lastRunAt = Date()
        lastRunWasFetchOnly = fetchOnly
        // Exit 1 with results just means some repos need attention
        problem = repos.isEmpty ? Porcelain.errorMessage(in: result.output) : nil

        let behind = Set(repos.filter { $0.state == .behind || $0.state == .diverged }.map(\.name))
        if inBackground {
            let newlyBehind = behind.subtracting(notifiedBehind).sorted()
            notifiedBehind = behind
            await notifyAboutNewCommits(in: newlyBehind)
        } else {
            // A pulled repo can be notified again when it falls behind later
            notifiedBehind.formIntersection(behind)
        }
    }

    private func fetchInBackgroundIfDue() async {
        guard autoFetchMinutes > 0, folder != nil, !isRunning else { return }
        let interval = TimeInterval(autoFetchMinutes * 60)
        let last = [lastAttemptAt, lastRunAt].compactMap(\.self).max()
        guard last.map({ Date().timeIntervalSince($0) >= interval }) ?? true else { return }
        await run(fetchOnly: true, inBackground: true)
    }

    /// For repos that fell behind their remote since the last background fetch.
    private func notifyAboutNewCommits(in newlyBehind: [String]) async {
        guard notifiesWhenBehind, !newlyBehind.isEmpty else { return }

        let names = newlyBehind.count <= 3
            ? newlyBehind.formatted(.list(type: .and).locale(Locale(identifier: "en_US")))
            : newlyBehind.prefix(2).joined(separator: ", ") + " and \(newlyBehind.count - 2) more"
        await Notifier.post(
            .reposBehind,
            title: newlyBehind.count == 1 ? "New commits in \(names)" : "New commits in \(newlyBehind.count) repos",
            body: newlyBehind.count == 1 ? "Pull it from Cursito." : "\(names). Pull them from Cursito."
        )
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

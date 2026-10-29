import AppKit
import CursitoCore
import Observation
import ServiceManagement

@MainActor
@Observable
final class SyncModel {
    enum Activity: Equatable {
        case idle, exporting, checking, quittingCursor, importing

        var label: String {
            switch self {
            case .idle: ""
            case .exporting: "Exporting…"
            case .checking: "Comparing…"
            case .quittingCursor: "Quitting Cursor…"
            case .importing: "Importing…"
            }
        }
    }

    struct Outcome {
        let message: String
        let failed: Bool
    }

    struct Backup: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    private static let syncFolderKey = "syncFolder"
    private static let archiveName = "cursor-sync.tar.gz"
    private static let pollInterval: Duration = .seconds(120)
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let iCloudDrive = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")

    private(set) var info: ExportInfo?
    private(set) var infoProblem: String?
    private(set) var activity: Activity = .idle
    private(set) var outcome: Outcome?
    private(set) var log = ""
    private(set) var changes: [SyncItem] = []
    private(set) var changesProblem: String?
    private(set) var backups: [Backup] = []
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    var syncFolder: URL {
        didSet {
            UserDefaults.standard.set(syncFolder, forKey: Self.syncFolderKey)
            Task { await refresh() }
        }
    }

    private let script = ScriptRunner(scriptURL: BundledScript.url(named: "sync-cursor"))

    init() {
        syncFolder = UserDefaults.standard.url(forKey: Self.syncFolderKey) ?? Self.defaultSyncFolder
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    var isBusy: Bool { activity != .idle }

    var syncPath: String { syncFolder.appending(path: Self.archiveName).path }

    var syncFolderDisplay: String {
        let path = syncFolder.path
        if path.hasPrefix(Self.iCloudDrive.path) {
            return "iCloud Drive" + path.dropFirst(Self.iCloudDrive.path.count)
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var menuBarSymbol: String {
        info?.isPendingImport == true
            ? "arrow.triangle.2.circlepath.circle.fill"
            : "arrow.triangle.2.circlepath"
    }

    // MARK: - Actions

    /// Re-reads who exported last and the local backups. Skipped while another run is going.
    func refresh() async {
        loadBackups()
        guard !isBusy else { return }

        guard FileManager.default.fileExists(atPath: syncPath) || hasICloudPlaceholder else {
            info = nil
            infoProblem = nil
            return
        }
        let result = await sync("info", syncPath: syncPath, porcelain: true)
        if result.succeeded, let parsed = ExportInfo(porcelain: result.output) {
            info = parsed
            infoProblem = nil
        } else {
            info = nil
            infoProblem = Porcelain.errorMessage(in: result.output)
        }
    }

    func exportThisMac() async {
        guard !isBusy else { return }
        if let info, info.isPendingImport, !confirm(
            title: "Replace the export from \(info.host)?",
            message: "This Mac hasn't imported it yet. Exporting now overwrites it with this Mac's setup.",
            action: "Export Anyway"
        ) { return }

        activity = .exporting
        let result = await sync("export", syncPath: syncPath)
        finish(result, success: "Exported this Mac's setup.")
        await refresh()
    }

    func loadChanges() async {
        guard !isBusy else { return }
        activity = .checking
        let result = await sync("diff", syncPath: syncPath, porcelain: true)
        activity = .idle
        if result.succeeded {
            changes = Porcelain.items(in: result.output)
            changesProblem = nil
        } else {
            changes = []
            changesProblem = Porcelain.errorMessage(in: result.output)
        }
    }

    func importLatest() async {
        let source = info.map { $0.isFromThisMac ? "this Mac" : $0.host } ?? "the other Mac"
        await runImport(from: syncPath, title: "Import the Cursor setup from \(source)?")
    }

    func restore(_ backup: Backup) async {
        await runImport(from: backup.url.path, title: "Restore the backup from \(backup.date.shortText)?")
    }

    func chooseSyncFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = syncFolder
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder both Macs can see, such as one in iCloud Drive."
        if panel.runModal() == .OK, let url = panel.url {
            syncFolder = url
        }
    }

    func revealSyncFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([syncFolder])
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            outcome = Outcome(message: "Couldn't change Open at Login: \(error.localizedDescription)", failed: true)
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Private

    /// Quits Cursor if needed, imports from `path` (an export or a backup) and reopens Cursor.
    private func runImport(from path: String, title: String) async {
        guard !isBusy else { return }
        let cursorWasRunning = CursorApp.isRunning
        let message = cursorWasRunning
            ? "Cursito quits Cursor, backs up this Mac's setup and replaces it. Cursor reopens when it's done."
            : "Cursito backs up this Mac's setup and replaces it."
        guard confirm(title: title, message: message, action: "Import") else { return }

        if cursorWasRunning {
            activity = .quittingCursor
            guard await CursorApp.quit() else {
                activity = .idle
                outcome = Outcome(message: "Cursor didn't quit. Save your work in Cursor and try again.", failed: true)
                return
            }
        }

        activity = .importing
        let result = await sync("import", syncPath: path, flags: ["-y"])
        finish(result, success: "Imported. OAuth MCP servers will ask you to log in again.")
        if cursorWasRunning {
            CursorApp.launch()
        }
        changes = []
        await refresh()
    }

    /// Runs `sync-cursor.sh <command> -d <syncPath>`; `porcelain` asks for parseable output.
    private func sync(
        _ command: String,
        syncPath: String,
        porcelain: Bool = false,
        flags: [String] = []
    ) async -> ScriptResult {
        await script.run([command, "-d", syncPath] + (porcelain ? ["-p"] : []) + flags)
    }

    private func finish(_ result: ScriptResult, success: String) {
        activity = .idle
        log = result.output
        outcome = result.succeeded
            ? Outcome(message: success, failed: false)
            : Outcome(message: Porcelain.errorMessage(in: result.output), failed: true)
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func loadBackups() {
        let root = Self.home.appending(path: ".cursito/backups")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        backups = urls
            .compactMap { url in formatter.date(from: url.lastPathComponent).map { Backup(url: url, date: $0) } }
            .sorted { $0.date > $1.date }
    }

    /// Older iCloud Drive versions swap evicted files for a ".name.icloud" placeholder.
    private var hasICloudPlaceholder: Bool {
        let placeholder = syncFolder.appending(path: ".\(Self.archiveName).icloud").path
        return FileManager.default.fileExists(atPath: placeholder)
    }

    private static var defaultSyncFolder: URL {
        FileManager.default.fileExists(atPath: iCloudDrive.path)
            ? iCloudDrive.appending(path: "Cursito")
            : home.appending(path: "Documents/Cursito")
    }
}

enum BundledScript {
    /// `<name>.sh` from the app bundle, or from the checkout's `scripts/` under `swift run`.
    static func url(named name: String) -> URL {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "sh") {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "scripts/\(name).sh")
    }
}

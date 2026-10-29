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

    /// An export that a newer one replaced, kept by the script in `previous-exports/`.
    struct PreviousExport: Identifiable, Hashable {
        let url: URL
        let date: Date
        let host: String
        var id: URL { url }
    }

    private static let syncFolderKey = "syncFolder"
    private static let notifiedExportKey = "notifiedExportEpoch"
    private static let archiveName = "cursor-sync.tar.gz"
    /// `sync-cursor.sh` exit status when an encrypted export needs a (different) passphrase.
    private static let passphraseStatus: Int32 = 3
    private static let minimumPassphraseLength = 8
    private static let pollInterval: Duration = .seconds(120)
    /// A fast export or import still shows on the menu bar icon instead of flickering.
    private static let minimumIconActivity: Duration = .seconds(1)
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let iCloudDrive = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")

    private(set) var info: ExportInfo?
    private(set) var infoProblem: String?
    private(set) var activity: Activity = .idle {
        didSet { updateIconActivity() }
    }
    /// What the menu bar icon shows: exports and imports only, held for `minimumIconActivity`.
    private(set) var iconActivity: Activity = .idle
    private var iconActivityStart = ContinuousClock.now
    private(set) var outcome: Outcome?
    private(set) var log = ""
    private(set) var changes: [SyncItem] = []
    private(set) var changesProblem: String?
    private(set) var backups: [Backup] = []
    private(set) var previousExports: [PreviousExport] = []
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    /// Set by the menu panel, which closes as soon as an alert or another app takes focus.
    var isMenuOpen = false
    /// Encrypts this Mac's exports and opens encrypted ones; saved in the keychain.
    private var passphrase = KeychainItem.exportPassphrase.read()

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

    var encryptsExports: Bool { passphrase != nil }

    var syncPath: String { syncFolder.appending(path: Self.archiveName).path }

    var syncFolderDisplay: String {
        let path = syncFolder.path
        if path.hasPrefix(Self.iCloudDrive.path) {
            return "iCloud Drive" + path.dropFirst(Self.iCloudDrive.path.count)
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var menuBarSymbol: String {
        switch iconActivity {
        case .exporting: "arrow.up.circle"
        case .quittingCursor, .importing: "arrow.down.circle"
        case .idle, .checking:
            info?.isPendingImport == true
                ? "arrow.triangle.2.circlepath.circle.fill"
                : "arrow.triangle.2.circlepath"
        }
    }

    // MARK: - Actions

    /// Re-reads who exported last and the local backups. Skipped while another run is going.
    func refresh() async {
        loadBackups()
        loadPreviousExports()
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
            await notifyIfNewExport(parsed)
        } else {
            info = nil
            infoProblem = Porcelain.errorMessage(in: result.output)
        }
    }

    /// - Parameter notify: posts the result when Cursito isn't in front; off for callers that show their own summary.
    /// - Returns: whether the export was written; false when it failed or the user cancelled.
    @discardableResult
    func exportThisMac(notify: Bool = true) async -> Bool {
        guard !isBusy else { return false }
        outcome = nil
        if let info, info.isPendingImport, !confirm(
            title: "Replace the export from \(info.host)?",
            message: "This Mac hasn't imported it yet. Exporting now overwrites it with this Mac's setup.",
            action: "Export Anyway"
        ) { return false }

        activity = .exporting
        let result = await sync("export", syncPath: syncPath)
        finish(result, success: "Exported this Mac's setup.")
        if notify {
            await notifyResult(result, success: "Cursor setup exported", body: "Import it on the other Mac.", failure: "Export failed")
        }
        await refresh()
        return result.succeeded
    }

    func loadChanges() async {
        guard !isBusy else { return }
        activity = .checking
        let result = await syncAskingForPassphrase("diff", porcelain: true)
        activity = .idle
        if result.succeeded {
            changes = Porcelain.items(in: result.output)
            changesProblem = nil
        } else {
            changes = []
            changesProblem = Porcelain.errorMessage(in: result.output)
        }
    }

    /// - Parameter notify: posts the result when Cursito isn't in front; off for callers that show their own summary.
    /// - Returns: whether the import ran and succeeded.
    @discardableResult
    func importLatest(notify: Bool = true) async -> Bool {
        let source = info.map { $0.isFromThisMac ? "this Mac" : $0.host } ?? "the other Mac"
        return await runImport(
            from: syncPath,
            title: "Import the Cursor setup from \(source)?",
            notification: notify ? ("Cursor setup imported from \(source)", "Import failed") : nil
        )
    }

    func restore(_ backup: Backup) async {
        await runImport(
            from: backup.url.path,
            title: "Restore the backup from \(backup.date.shortText)?",
            notification: ("Backup from \(backup.date.shortText) restored", "Restore failed")
        )
    }

    /// Imports an export a newer one replaced, e.g. one this Mac overwrote before importing it.
    func importPrevious(_ export: PreviousExport) async {
        await runImport(
            from: export.url.path,
            title: "Import the export from \(export.host), \(export.date.shortText)?",
            notification: ("Export from \(export.host) imported", "Import failed")
        )
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

    /// Turns encryption on, changes the passphrase or turns it off.
    func editEncryption() {
        var problem: String?
        while true {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = encryptsExports ? "Change the Export Passphrase" : "Encrypt Exports"
            alert.informativeText = (problem.map { "\($0)\n\n" } ?? "")
                + "Exports from this Mac are encrypted with AES-256, so only a Mac with the passphrase can read them. "
                + "Use the same passphrase on the other Mac. Cursito keeps it in this Mac's keychain."
            let field = Self.secureField(placeholder: "Passphrase")
            let repeated = Self.secureField(placeholder: "Repeat passphrase")
            field.frame = NSRect(x: 0, y: 32, width: 260, height: 24)
            repeated.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
            fields.addSubview(field)
            fields.addSubview(repeated)
            alert.accessoryView = fields
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: encryptsExports ? "Save" : "Turn On")
            alert.addButton(withTitle: "Cancel")
            if encryptsExports {
                alert.addButton(withTitle: "Turn Off")
            }

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let value = field.stringValue
                if value.count < Self.minimumPassphraseLength {
                    problem = "Use at least \(Self.minimumPassphraseLength) characters."
                } else if value != repeated.stringValue {
                    problem = "The passphrases don't match."
                } else {
                    savePassphrase(value)
                    outcome = Outcome(message: "Exports from this Mac are encrypted from the next one on.", failed: false)
                    return
                }
            case .alertThirdButtonReturn:
                KeychainItem.exportPassphrase.delete()
                passphrase = nil
                outcome = Outcome(message: "Exports from this Mac are no longer encrypted.", failed: false)
                return
            default:
                return
            }
        }
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

    /// Once per export from the other Mac, including one that arrived while Cursito was closed.
    private func notifyIfNewExport(_ info: ExportInfo) async {
        let epoch = Int(info.exportedAt.timeIntervalSince1970)
        guard info.isPendingImport, epoch > UserDefaults.standard.integer(forKey: Self.notifiedExportKey) else { return }
        UserDefaults.standard.set(epoch, forKey: Self.notifiedExportKey)
        await Notifier.post(
            .newExport,
            title: "New Cursor setup from \(info.host)",
            body: "Open Cursito to review the changes and import them."
        )
    }

    /// Quits Cursor if needed, imports from `path` (an export or a backup) and reopens Cursor.
    /// - Parameter notification: titles for the success and failure notification; nil posts none.
    /// - Returns: whether the import ran and succeeded.
    @discardableResult
    private func runImport(from path: String, title: String, notification: (success: String, failure: String)?) async -> Bool {
        guard !isBusy else { return false }
        outcome = nil
        // Ask for the passphrase before quitting Cursor, not halfway through the import
        let archiveInfo = path == syncPath ? info : await exportInfo(at: path)
        if let archiveInfo, archiveInfo.isEncrypted {
            activity = .checking
            let check = await syncAskingForPassphrase("verify", at: path, about: archiveInfo, porcelain: true)
            activity = .idle
            guard check.succeeded else {
                if check.exitCode != Self.passphraseStatus {
                    finish(check, success: "")
                }
                return false
            }
        }
        let cursorWasRunning = CursorApp.isRunning
        let message = cursorWasRunning
            ? "Cursito quits Cursor, backs up this Mac's setup and replaces it. Cursor reopens when it's done."
            : "Cursito backs up this Mac's setup and replaces it."
        guard confirm(title: title, message: message, action: "Import") else { return false }

        if cursorWasRunning {
            activity = .quittingCursor
            guard await CursorApp.quit() else {
                activity = .idle
                outcome = Outcome(message: "Cursor didn't quit. Save your work in Cursor and try again.", failed: true)
                return false
            }
        }

        activity = .importing
        let result = await sync("import", syncPath: path, flags: ["-y"])
        finish(result, success: "Imported. OAuth MCP servers will ask you to log in again.")
        if cursorWasRunning {
            CursorApp.launch()
        }
        if let notification {
            await notifyResult(
                result,
                success: notification.success,
                body: "OAuth MCP servers will ask you to log in again.",
                failure: notification.failure
            )
        }
        changes = []
        await refresh()
        return result.succeeded
    }

    /// Skipped while the menu is open: its outcome row already says it.
    private func notifyResult(_ result: ScriptResult, success: String, body: String, failure: String) async {
        guard !isMenuOpen else { return }
        if result.succeeded {
            await Notifier.post(.syncResult, title: success, body: body)
        } else {
            await Notifier.post(.syncResult, title: failure, body: Porcelain.errorMessage(in: result.output))
        }
    }

    private func updateIconActivity() {
        let shown: Activity = switch activity {
        case .exporting, .quittingCursor, .importing: activity
        case .idle, .checking: .idle
        }
        if shown != .idle {
            if iconActivity == .idle {
                iconActivityStart = .now
            }
            iconActivity = shown
            return
        }
        guard iconActivity != .idle else { return }
        let remaining = Self.minimumIconActivity - (ContinuousClock.now - iconActivityStart)
        guard remaining > .zero else {
            iconActivity = .idle
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard let self, self.activity == .idle || self.activity == .checking else { return }
            self.iconActivity = .idle
        }
    }

    /// Runs `sync-cursor.sh <command> -d <syncPath>`; `porcelain` asks for parseable output.
    /// The passphrase goes in the environment: arguments are visible to every process.
    private func sync(
        _ command: String,
        syncPath: String,
        porcelain: Bool = false,
        flags: [String] = [],
        passphrase: String? = nil
    ) async -> ScriptResult {
        let environment = (passphrase ?? self.passphrase).map { ["CURSITO_PASSPHRASE": $0] } ?? [:]
        return await script.run([command, "-d", syncPath] + (porcelain ? ["-p"] : []) + flags, environment: environment)
    }

    /// Runs a command on an export (the current one by default), asking for the passphrase
    /// until it opens or the user cancels.
    private func syncAskingForPassphrase(
        _ command: String,
        at path: String? = nil,
        about export: ExportInfo? = nil,
        porcelain: Bool = false
    ) async -> ScriptResult {
        let path = path ?? syncPath
        let export = export ?? info
        var result = await sync(command, syncPath: path, porcelain: porcelain)
        var wasWrong = passphrase != nil
        while result.exitCode == Self.passphraseStatus {
            guard let entered = askForExportPassphrase(about: export, wasWrong: wasWrong) else { return result }
            result = await sync(command, syncPath: path, porcelain: porcelain, passphrase: entered)
            if result.exitCode != Self.passphraseStatus {
                savePassphrase(entered)
            }
            wasWrong = true
        }
        return result
    }

    /// The manifest of an archive other than the current export, such as a previous export.
    private func exportInfo(at path: String) async -> ExportInfo? {
        guard path.hasSuffix(".tar.gz") else { return nil }
        let result = await sync("info", syncPath: path, porcelain: true)
        return result.succeeded ? ExportInfo(porcelain: result.output) : nil
    }

    private func askForExportPassphrase(about export: ExportInfo?, wasWrong: Bool) -> String? {
        let host = export.map { $0.isFromThisMac ? "this Mac" : $0.host } ?? "the other Mac"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = wasWrong ? "Wrong passphrase" : "The export from \(host) is encrypted"
        alert.informativeText = "Enter the passphrase set in Cursito on \(host). "
            + "Cursito keeps it in this Mac's keychain and encrypts this Mac's exports with it too."
        let field = Self.secureField(placeholder: "Passphrase")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    /// Keeps the passphrase for this session even if the keychain refuses it.
    private func savePassphrase(_ value: String) {
        passphrase = value
        do {
            try KeychainItem.exportPassphrase.save(value)
        } catch {
            outcome = Outcome(
                message: "Couldn't save the passphrase in the keychain: \(error.localizedDescription)",
                failed: true
            )
        }
    }

    private static func secureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        return field
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

    /// `previous-exports/<yyyyMMdd-HHmmss> <host>.tar.gz`, newest first; the name says it all,
    /// so listing them never downloads one from iCloud.
    private func loadPreviousExports() {
        let root = syncFolder.appending(path: "previous-exports")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        previousExports = names
            .compactMap { name -> PreviousExport? in
                // An evicted file can show up as its ".<name>.icloud" placeholder; the script downloads it
                var name = name
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                }
                guard name.hasSuffix(".tar.gz"), let date = formatter.date(from: String(name.prefix(15))) else { return nil }
                let host = name.dropFirst(16).dropLast(".tar.gz".count)
                return PreviousExport(url: root.appending(path: name), date: date, host: host.isEmpty ? "unknown Mac" : String(host))
            }
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

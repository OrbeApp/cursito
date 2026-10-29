import Foundation

/// What `sync-cursor.sh info -p` reports about the export in the sync location.
public struct ExportInfo: Equatable, Sendable {
    public let host: String
    public let machineID: String
    public let exportedAt: Date
    public let cursorVersion: String
    public let thisMachineID: String
    /// Export timestamp of the last export imported on this Mac, if any.
    public let lastImportedExportAt: Date?
    /// Reading it needs the passphrase it was exported with.
    public let isEncrypted: Bool

    public var isFromThisMac: Bool { machineID == thisMachineID }

    /// True when another Mac exported a setup this Mac hasn't imported yet.
    public var isPendingImport: Bool {
        guard !isFromThisMac else { return false }
        guard let lastImportedExportAt else { return true }
        return exportedAt > lastImportedExportAt
    }

    /// Parses `info -p` output; nil when a required key is missing.
    public init?(porcelain output: String) {
        let values = Porcelain.keyValues(in: output)
        guard
            let host = values["host"],
            let machineID = values["machine_id"],
            let epoch = values["epoch"].flatMap(TimeInterval.init),
            let thisMachineID = values["this_machine_id"]
        else { return nil }

        let lastImport = values["last_import_epoch"].flatMap(TimeInterval.init) ?? 0
        self.host = host
        self.machineID = machineID
        self.exportedAt = Date(timeIntervalSince1970: epoch)
        self.cursorVersion = values["cursor"] ?? ""
        self.thisMachineID = thisMachineID
        self.lastImportedExportAt = lastImport > 0 ? Date(timeIntervalSince1970: lastImport) : nil
        self.isEncrypted = values["encrypted"] == "1"
    }
}

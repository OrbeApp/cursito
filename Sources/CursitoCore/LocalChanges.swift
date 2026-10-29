import Foundation

/// What `sync-cursor.sh status -p` reports: what changed on this Mac since its last
/// export or import, so a change made here isn't lost by forgetting to export it.
public struct LocalChanges: Equatable, Sendable {
    public enum LastSync: String, Sendable {
        case export, `import`
    }

    public let lastSync: LastSync
    public let lastSyncAt: Date
    public let items: [SyncItem]

    public var isEmpty: Bool { items.isEmpty }

    /// Parses `status -p` output; nil before this Mac's first export or import.
    public init?(porcelain output: String) {
        let values = Porcelain.keyValues(in: output)
        guard
            let lastSync = values["last_sync"].flatMap(LastSync.init(rawValue:)),
            let epoch = values["last_sync_epoch"].flatMap(TimeInterval.init)
        else { return nil }
        self.lastSync = lastSync
        self.lastSyncAt = Date(timeIntervalSince1970: epoch)
        self.items = Porcelain.items(in: output)
    }

    /// "settings.json, .codex/skills/ and 2 more"
    public func summary(listing limit: Int = 2) -> String {
        let names = items.map { Self.displayName(of: $0.name) }
        guard names.count > limit else { return names.formatted(.list(type: .and).locale(Locale(identifier: "en_US"))) }
        return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
    }

    /// Item names without the Cursor user folder prefix: "settings.json", "snippets/".
    public static func displayName(of item: String) -> String {
        let cursorUser = "Library/Application Support/Cursor/User/"
        return item.hasPrefix(cursorUser) ? String(item.dropFirst(cursorUser.count)) : item
    }
}

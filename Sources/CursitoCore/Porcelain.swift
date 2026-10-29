import Foundation

/// One line of `sync-cursor.sh -p` output: a synced item and what happened to it.
public struct SyncItem: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable {
        case ok, same, new, changed, skip, warn, error
    }

    public let state: State
    public let name: String
    public let summary: String
    public var details: [String]

    public var id: String { name }

    public init(state: State, name: String, summary: String, details: [String] = []) {
        self.state = state
        self.name = name
        self.summary = summary
        self.details = details
    }
}

/// Parses the machine-readable output of `sync-cursor.sh -p`.
public enum Porcelain {
    /// `ITEM<TAB>state<TAB>name<TAB>summary` lines, with the `DETAIL<TAB>name<TAB>text`
    /// lines that follow them attached to their item.
    public static func items(in output: String) -> [SyncItem] {
        var items: [SyncItem] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            switch fields[0] {
            case "ITEM":
                items.append(SyncItem(
                    state: SyncItem.State(rawValue: fields[1]) ?? .error,
                    name: fields[2],
                    summary: fields.count > 3 ? fields[3] : ""
                ))
            case "DETAIL":
                if let index = items.lastIndex(where: { $0.name == fields[1] }) {
                    items[index].details.append(fields[2...].joined(separator: "\t"))
                }
            default:
                continue
            }
        }
        return items
    }

    /// `key=value` lines, as printed by `info -p` and in an export's MANIFEST.
    public static func keyValues(in output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") where !line.contains("\t") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return values
    }

    /// The reason a run failed: the script's last `error:` line, or else its last line.
    public static func errorMessage(in output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let error = lines.last(where: { $0.hasPrefix("error:") }) {
            return String(error.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last(where: { !$0.isEmpty }) ?? "sync-cursor.sh failed without output"
    }
}

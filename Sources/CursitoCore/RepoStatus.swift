import Foundation

/// One repo from `update-repos.sh -p`: what the update did and git's own messages.
public struct RepoStatus: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable {
        case ok = "OK"
        case pulled = "PULLED"
        case ahead = "AHEAD"
        case behind = "BEHIND"
        case dirty = "DIRTY"
        case diverged = "DIVERGED"
        case skip = "SKIP"
        case error = "ERROR"

        /// The script leaves these alone; you have to sort them out by hand.
        public var needsAttention: Bool {
            self == .dirty || self == .diverged || self == .error
        }
    }

    public let state: State
    public let name: String
    public let detail: String
    public var log: [String]

    public var id: String { name }

    public init(state: State, name: String, detail: String, log: [String] = []) {
        self.state = state
        self.name = name
        self.detail = detail
        self.log = log
    }
}

extension Porcelain {
    /// `REPO<TAB>state<TAB>name<TAB>detail` lines, with the `LOG<TAB>name<TAB>text`
    /// lines that follow them attached to their repo.
    public static func repos(in output: String) -> [RepoStatus] {
        var repos: [RepoStatus] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            switch fields[0] {
            case "REPO":
                repos.append(RepoStatus(
                    state: RepoStatus.State(rawValue: fields[1]) ?? .error,
                    name: fields[2],
                    detail: fields.count > 3 ? fields[3] : ""
                ))
            case "LOG":
                if let index = repos.lastIndex(where: { $0.name == fields[1] }) {
                    repos[index].log.append(fields[2...].joined(separator: "\t"))
                }
            default:
                continue
            }
        }
        return repos
    }
}

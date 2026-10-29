import SwiftUI

@main
struct CursitoApp: App {
    @State private var model: SyncModel
    @State private var repos: ReposModel
    @State private var handoff: Handoff
    @State private var usage = UsageModel()
    @State private var updates = UpdateChecker()

    init() {
        let model = SyncModel()
        let repos = ReposModel()
        _model = State(initialValue: model)
        _repos = State(initialValue: repos)
        _handoff = State(initialValue: Handoff(sync: model, repos: repos))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, usage: usage, repos: repos, handoff: handoff, updates: updates)
        } label: {
            MenuBarLabel(sync: model, usage: usage)
        }
        .menuBarExtraStyle(.window)

        Window("Cursor Setup Changes", id: WindowID.changes) {
            ChangesView(model: model)
        }
        .defaultSize(width: 560, height: 480)

        Window("Cursor Sync Log", id: WindowID.log) {
            LogView(model: model)
        }
        .defaultSize(width: 560, height: 360)

        Window("Cursor Usage", id: WindowID.usage) {
            UsageView(usage: usage)
        }
        .defaultSize(width: 640, height: 520)

        Window("Git Repos", id: WindowID.repos) {
            ReposView(repos: repos)
        }
        .defaultSize(width: 600, height: 480)
    }
}

enum WindowID {
    static let changes = "changes"
    static let log = "log"
    static let usage = "usage"
    static let repos = "repos"
}

extension Locale {
    /// The UI is English-only, so dates and numbers are English too, in the user's region format.
    static let ui = Locale(identifier: "en_\(Locale.current.region?.identifier ?? "US")")
}

extension Date {
    var shortText: String {
        formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(.ui))
    }

    var longText: String {
        formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(.ui))
    }

    var relativeText: String {
        formatted(Date.RelativeFormatStyle(presentation: .named).locale(.ui))
    }

    /// "Oct 1"
    var dayText: String {
        formatted(Date.FormatStyle().month(.abbreviated).day().locale(.ui))
    }
}

extension Double {
    /// Cents as dollars, e.g. 1234.5 → "$12.35". Cursor bills in USD.
    var centsText: String {
        (self / 100).formatted(.currency(code: "USD").presentation(.narrow).locale(.ui))
    }

    /// Cents as whole dollars, e.g. 18432 → "$184".
    var wholeDollarsText: String {
        (self / 100).formatted(.currency(code: "USD").presentation(.narrow).precision(.fractionLength(0)).locale(.ui))
    }
}

extension Int {
    /// "1.2M"
    var compactText: String {
        formatted(.number.notation(.compactName).locale(.ui))
    }
}

extension View {
    @ViewBuilder
    func prominentButton(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

import SwiftUI

@main
struct CursitoApp: App {
    @State private var model = SyncModel()
    @State private var repos = ReposModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, repos: repos)
        } label: {
            Image(systemName: model.menuBarSymbol)
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

        Window("Git Repos", id: WindowID.repos) {
            ReposView(repos: repos)
        }
        .defaultSize(width: 600, height: 480)
    }
}

enum WindowID {
    static let changes = "changes"
    static let log = "log"
    static let repos = "repos"
}

extension Date {
    /// The UI is English-only, so dates are English too, in the user's region format.
    private static let locale = Locale(identifier: "en_\(Locale.current.region?.identifier ?? "US")")

    var shortText: String {
        formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Self.locale))
    }

    var longText: String {
        formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Self.locale))
    }

    var relativeText: String {
        formatted(Date.RelativeFormatStyle(presentation: .named).locale(Self.locale))
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

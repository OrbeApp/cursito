import CursitoCore
import SwiftUI

/// What an import would change on this Mac, from `sync-cursor.sh diff`.
struct ChangesView: View {
    let model: SyncModel
    @State private var showsUnchanged = false

    private var visibleChanges: [SyncItem] {
        showsUnchanged ? model.changes : model.changes.filter { $0.state != .same }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Cursor setup changes an import would make", systemImage: "cursorarrow.rays")
                    .font(.headline)
                if let info = model.info {
                    Text("Export from \(info.host), \(info.exportedAt.shortText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Toggle("Show unchanged", isOn: $showsUnchanged)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Refresh") {
                    Task { await model.loadChanges() }
                }
                Button("Import…") {
                    Task { await model.importLatest() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.info.map(\.isFromThisMac) ?? true)
            }
            .disabled(model.isBusy)
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await model.loadChanges() }
    }

    @ViewBuilder
    private var content: some View {
        if model.activity == .checking && model.changes.isEmpty {
            ProgressView("Comparing…")
        } else if let problem = model.changesProblem {
            ContentUnavailableView("Can't compare", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if model.changes.isEmpty {
            ContentUnavailableView("Nothing to compare yet", systemImage: "tray")
        } else if visibleChanges.isEmpty {
            ContentUnavailableView(
                "Everything matches",
                systemImage: "checkmark.circle",
                description: Text("This Mac already has the exported setup.")
            )
        } else {
            List(visibleChanges) { item in
                ChangeRow(item: item)
            }
        }
    }
}

private struct ChangeRow: View {
    let item: SyncItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
            ForEach(item.details, id: \.self) { detail in
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch item.state {
        case .new: "plus.circle.fill"
        case .changed: "pencil.circle.fill"
        case .same, .ok: "checkmark.circle"
        case .skip: "minus.circle"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .new: .green
        case .changed: .orange
        case .same, .ok, .skip: .secondary
        case .warn: .yellow
        case .error: .red
        }
    }
}

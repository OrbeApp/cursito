import SwiftUI

/// Output of the last export or import, as printed by `sync-cursor.sh`.
struct LogView: View {
    let model: SyncModel

    var body: some View {
        ScrollView {
            Text(model.log.isEmpty ? "Nothing has run yet." : model.log)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(model.log.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

import SwiftUI

/// The Cloud Agents window: connects a Cursor user API key, or replaces and disconnects it.
struct CloudAgentsView: View {
    let cloudAgents: CloudAgentsModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        CloudAgentsSettingsForm(cloudAgents: cloudAgents) { dismissWindow(id: WindowID.cloudAgents) }
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CloudAgentsSettingsForm: View {
    let cloudAgents: CloudAgentsModel
    var onClose: (() -> Void)?

    @State private var apiKey = ""
    @State private var error: String?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField(
                        "Cursor API key",
                        text: $apiKey,
                        prompt: Text(cloudAgents.isConnected ? "Saved in the keychain" : "Paste the key")
                    )
                    if cloudAgents.isConnected {
                        LabeledContent("Connected as", value: cloudAgents.account)
                    }
                } header: {
                    Label("Connect Cursor's Cloud Agents API", systemImage: "cloud")
                        .font(.headline)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Create a user API key in the Cursor dashboard, under Integrations › API Keys. An Admin API key won't work.")
                            .foregroundStyle(.secondary)
                        Link("Open the Cursor dashboard", destination: URL(string: "https://cursor.com/dashboard")!)
                        Text("The key is stored in your macOS keychain. It could launch agents; Cursito only uses it to read them.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            HStack {
                if cloudAgents.isConnected {
                    Button("Disconnect", role: .destructive) {
                        cloudAgents.disconnect()
                        onClose?()
                    }
                }
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                }
                if let onClose {
                    Button("Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                Button(cloudAgents.isConnected ? "Save" : "Connect") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isChecking || apiKey.isEmpty)
            }
            .padding([.horizontal, .bottom])
        }
    }

    private func save() async {
        isChecking = true
        error = await cloudAgents.connect(apiKey: apiKey)
        isChecking = false
        if error == nil {
            apiKey = ""
            onClose?()
        }
    }
}

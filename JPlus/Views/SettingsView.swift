import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var draftKey = ""
    @State private var status: String?
    @State private var isSaving = false

    private static let consoleURL = URL(string: "https://platform.claude.com/settings/keys")!

    var body: some View {
        Form {
            Section {
                SecureField("Claude API key", text: $draftKey, prompt: Text("sk-ant-…"))
                    .onSubmit(save)
                HStack {
                    Button("Save", action: save)
                        .disabled(isSaving || draftKey == settings.claudeAPIKey)
                    if !settings.claudeAPIKey.isEmpty {
                        Button("Remove", role: .destructive) {
                            draftKey = ""
                            save()
                        }
                    }
                    Spacer()
                    if let status {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Link("Get an API key…", destination: Self.consoleURL)
                    .font(.callout)
            } header: {
                Text("Draft with Claude")
            } footer: {
                Text("Used only when you press Draft with Claude on a new ticket. The screenshot and your notes are sent to Anthropic's API; the key is stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task {
            await settings.load()
            draftKey = settings.claudeAPIKey
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await settings.saveClaudeAPIKey(draftKey)
                status = settings.hasClaudeAPIKey ? "Saved" : "Removed"
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

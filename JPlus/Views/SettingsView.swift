import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                ClaudeAPIKeyEditor()
            } header: {
                Text("Draft with Claude")
            } footer: {
                Text("Used only when you press Draft with Claude on a new ticket. The screenshot and your notes are sent to Anthropic's API; the key is stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

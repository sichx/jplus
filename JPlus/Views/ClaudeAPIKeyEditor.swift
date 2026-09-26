import SwiftUI

/// Edit the Claude API key used by Draft with Claude. Shared by the
/// Account screen and the Settings window.
struct ClaudeAPIKeyEditor: View {
    @Environment(SettingsStore.self) private var settings

    @State private var draftKey = ""
    @State private var status: String?
    @State private var isSaving = false

    private static let consoleURL = URL(string: "https://platform.claude.com/settings/keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SecureField("Claude API key", text: $draftKey, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(isSaving || draftKey == settings.claudeAPIKey)
                if settings.hasClaudeAPIKey {
                    Button("Remove", role: .destructive) {
                        draftKey = ""
                        save()
                    }
                    .disabled(isSaving)
                }
            }
            HStack(spacing: 12) {
                statusLabel
                Spacer()
                Link("Get an API key…", destination: Self.consoleURL)
            }
            .font(.callout)
        }
        .task {
            await settings.load()
            draftKey = settings.claudeAPIKey
        }
        .onChange(of: settings.claudeAPIKey) { draftKey = settings.claudeAPIKey }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let status {
            Text(status).foregroundStyle(.secondary)
        } else if settings.hasClaudeAPIKey {
            Label("Key saved · ending in \(String(settings.claudeAPIKey.suffix(4)))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Text("No key set. Draft with Claude is disabled.")
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        isSaving = true
        status = nil
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

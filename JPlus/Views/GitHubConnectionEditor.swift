import SwiftUI

struct GitHubConnectionEditor: View {
    @Environment(GitHubStore.self) private var github
    @Environment(SessionStore.self) private var session
    @State private var organizationURL = GitHubOrganization.suggestedURL
    @State private var draftToken = ""
    @State private var isSaving = false
    @State private var status: String?
    @State private var error: String?

    private var currentConnection: GitHubConnection? {
        github.accountID == session.currentAccountID ? github.connection : nil
    }

    private var tokenURL: URL {
        let host = (try? GitHubOrganization(url: organizationURL))?.host ?? "volohealth.ghe.com"
        return URL(string: "https://\(host)/settings/personal-access-tokens/new")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Organization URL", text: $organizationURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            SecureField("GitHub token", text: $draftToken, prompt: Text(currentConnection == nil ? "Personal access token" : "Leave blank to keep the saved token"))
                .textFieldStyle(.roundedBorder)
            Text("Use a token from this GitHub host with Contents: write for the repositories you want to use. Choose a repository when creating a branch. Your organization may require approval.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(currentConnection == nil ? "Connect" : "Save & Verify", action: save)
                    .disabled(isSaving || session.currentAccountID == nil || !github.isLoaded || organizationURL.isEmpty)
                if currentConnection != nil {
                    Button("Disconnect", role: .destructive, action: disconnect).disabled(isSaving)
                }
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Link("Create a token…", destination: tokenURL)
            }
            .scaledFont(.callout)

            if let message = error ?? github.loadError {
                Text(message).foregroundStyle(.red).scaledFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status {
                Text(status).foregroundStyle(.secondary).scaledFont(.callout)
            } else if let connection = currentConnection {
                Label("Connected to \(connection.organization.name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).scaledFont(.callout)
            } else if session.currentAccountID == nil {
                Text("Sign in to Jira to configure a GitHub connection for that account.")
                    .foregroundStyle(.secondary).scaledFont(.callout)
            }
        }
        .disabled(isSaving)
        .task(id: session.currentAccountID) {
            await github.load(for: session.currentAccountID)
            resetDraft()
        }
        .onChange(of: github.connection?.organization) { resetDraft() }
    }

    private func resetDraft() {
        organizationURL = currentConnection?.organization.webURL.absoluteString ?? GitHubOrganization.suggestedURL
        draftToken = ""
        error = nil
        status = nil
    }

    private func save() {
        guard let id = session.currentAccountID else { return }
        isSaving = true
        error = nil
        status = nil
        Task {
            defer { isSaving = false }
            do {
                try await github.connect(organizationURL: organizationURL, token: draftToken, for: id)
                guard session.currentAccountID == id else { return }
                draftToken = ""
                status = "Saved. Repository listing verified; creation also requires write permission."
            } catch where error.isCancellation {
                return
            } catch {
                guard session.currentAccountID == id else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        guard let id = session.currentAccountID else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await github.disconnect(for: id)
                guard session.currentAccountID == id else { return }
                resetDraft()
                status = "Disconnected"
            } catch where error.isCancellation {
                return
            } catch { self.error = error.localizedDescription }
        }
    }
}

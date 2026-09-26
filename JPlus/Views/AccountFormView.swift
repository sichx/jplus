import SwiftUI

/// Site + email + API token form, used to add a new account or edit a saved
/// one. Nothing is saved until Jira accepts the credentials.
struct AccountFormView: View {
    enum Mode: Equatable {
        /// First-run form shown directly on the sign-in screen.
        case firstAccount
        /// "Add Account…" sheet.
        case add
        case edit(SavedAccount)
    }

    let mode: Mode
    var onFinished: () -> Void = {}

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var site = ""
    @State private var email = ""
    @State private var apiToken = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case site, email, token }

    private static let tokenHelpURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    private var editingAccount: SavedAccount? {
        if case .edit(let account) = mode { return account }
        return nil
    }

    private var title: String {
        switch mode {
        case .firstAccount: return "Sign in to Jira"
        case .add: return "Add Jira Account"
        case .edit: return "Edit Account"
        }
    }

    private var subtitle: String {
        switch mode {
        case .firstAccount, .add: return "Connect to a Jira Cloud site with an API token. It's saved on this Mac once Jira accepts it."
        case .edit: return "Changes are checked with Jira before they're saved."
        }
    }

    private var submitTitle: String {
        editingAccount == nil ? "Sign In" : "Save"
    }

    private var canSubmit: Bool {
        let hasSite = !site.trimmingCharacters(in: .whitespaces).isEmpty
        let hasEmail = !email.trimmingCharacters(in: .whitespaces).isEmpty
        let hasToken = !apiToken.isEmpty || editingAccount != nil
        return hasSite && hasEmail && hasToken && !isSaving
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                if mode == .firstAccount {
                    AppIconView(size: 80)
                }
                Text(title)
                    .font(mode == .firstAccount ? .title.weight(.semibold) : .title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Site", text: $site, prompt: Text("acme.atlassian.net"))
                    .focused($focusedField, equals: .site)
                TextField("Email", text: $email, prompt: Text("you@example.com"))
                    .focused($focusedField, equals: .email)
                    .textContentType(.username)
                SecureField("API token", text: $apiToken,
                            prompt: Text(editingAccount == nil ? "" : "Leave blank to keep the saved token"))
                    .focused($focusedField, equals: .token)
                    .textContentType(.password)

                Link("Create an API token…", destination: Self.tokenHelpURL)
                    .font(.callout)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 440)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(isSaving)
            .onSubmit(submit)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if mode != .firstAccount {
                    Button("Cancel", role: .cancel) { close() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                }
                Button(action: submit) {
                    Group {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(submitTitle)
                        }
                    }
                    .frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(minWidth: mode == .firstAccount ? nil : 500)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        if let account = editingAccount {
            site = account.credentials.siteHost
            email = account.credentials.email
            focusedField = .token
            if account.tokenRejected {
                errorMessage = "Jira rejected the saved token. Enter a new one."
            }
        } else {
            focusedField = .site
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                if let account = editingAccount {
                    try await session.updateAccount(id: account.id, site: site, email: email, apiToken: apiToken)
                } else {
                    try await session.addAccount(site: site, email: email, apiToken: apiToken)
                }
                apiToken = ""
                close()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func close() {
        onFinished()
        if mode != .firstAccount { dismiss() }
    }
}

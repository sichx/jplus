import SwiftUI

struct SignInView: View {
    @Environment(SessionStore.self) private var session

    @AppStorage("lastSite") private var site = ""
    @AppStorage("lastEmail") private var email = ""
    @State private var apiToken = ""

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case site, email, token }

    private static let tokenHelpURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Sign in to Jira")
                    .font(.title.weight(.semibold))
                Text("Connect to a Jira Cloud site with an API token.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Site", text: $site, prompt: Text("acme.atlassian.net"))
                    .focused($focusedField, equals: .site)
                TextField("Email", text: $email, prompt: Text("you@example.com"))
                    .focused($focusedField, equals: .email)
                    .textContentType(.username)
                SecureField("API token", text: $apiToken)
                    .focused($focusedField, equals: .token)
                    .textContentType(.password)

                Link("Create an API token…", destination: Self.tokenHelpURL)
                    .font(.callout)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 420)
            .disabled(isSigningIn)
            .onSubmit(submit)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button(action: submit) {
                Group {
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .frame(minWidth: 100)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSigningIn || !canSubmit)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focusedField = site.isEmpty ? .site : (email.isEmpty ? .email : .token) }
    }

    private var canSubmit: Bool {
        !site.trimmingCharacters(in: .whitespaces).isEmpty
            && !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiToken.isEmpty
    }

    private func submit() {
        guard canSubmit, !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await session.signIn(site: site, email: email, apiToken: apiToken)
                apiToken = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SignInView()
        .environment(SessionStore())
}

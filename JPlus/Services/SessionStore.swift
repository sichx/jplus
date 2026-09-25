import Foundation
import Observation

/// Owns authentication state for the app. Injected via `.environment(session)`.
@Observable
final class SessionStore {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(JiraUser)
    }

    private(set) var state: State = .restoring
    private(set) var client: JiraClient?

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var currentUser: JiraUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    private let keychain = KeychainStore(service: "co.interactivelabs.jplus", account: "jira-credentials")

    /// Called once at launch: reload saved credentials and verify them.
    func restore() async {
        guard case .restoring = state else { return }

        let keychain = self.keychain
        let saved = await Task.detached { try? keychain.load() }.value
        guard let data = saved,
              let credentials = try? JSONDecoder().decode(JiraCredentials.self, from: data)
        else {
            state = .signedOut
            return
        }

        let client = JiraClient(credentials: credentials)
        do {
            let user = try await client.myself()
            self.client = client
            state = .signedIn(user)
        } catch JiraError.unauthorized {
            // Token revoked or changed; forget it.
            Task.detached { try? keychain.delete() }
            state = .signedOut
        } catch {
            // Offline or transient: keep the credentials, stay signed out for now.
            state = .signedOut
        }
    }

    /// Verifies credentials against Jira, then persists them.
    func signIn(site: String, email: String, apiToken: String) async throws {
        guard let siteURL = JiraSite.normalize(site) else {
            throw SignInError.invalidSite
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else {
            throw SignInError.missingFields
        }

        let credentials = JiraCredentials(siteURL: siteURL, email: trimmedEmail, apiToken: trimmedToken)
        let client = JiraClient(credentials: credentials)
        let user = try await client.myself()

        let data = try JSONEncoder().encode(credentials)
        let keychain = self.keychain
        try await Task.detached { try keychain.save(data) }.value

        self.client = client
        state = .signedIn(user)
    }

    func signOut() {
        let keychain = self.keychain
        Task.detached { try? keychain.delete() }
        client = nil
        state = .signedOut
    }

    enum SignInError: LocalizedError {
        case invalidSite
        case missingFields

        var errorDescription: String? {
            switch self {
            case .invalidSite: return "Enter a valid Jira site, like acme.atlassian.net."
            case .missingFields: return "Email and API token are required."
            }
        }
    }
}

import Foundation
import Observation

/// Owns sign-in state and the saved accounts. Injected via `.environment(session)`.
@Observable
final class SessionStore {
    enum State: Equatable {
        case restoring
        /// Account picker / sign-in form.
        case signedOut
        case signedIn(JiraUser)
    }

    private(set) var state: State = .restoring
    private(set) var client: JiraClient?
    private(set) var currentAccountID: UUID?
    /// Message for the account picker, e.g. why automatic sign-in failed.
    var notice: String?

    let accounts: AccountStore
    private var cachedCloudId: String?

    init(accounts: AccountStore = AccountStore(persistence: KeychainAccountPersistence())) {
        self.accounts = accounts
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var currentUser: JiraUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    var currentAccount: SavedAccount? { accounts.account(id: currentAccountID) }

    /// Cloud id of the signed-in site, fetched once.
    func cloudId() async throws -> String {
        if let cachedCloudId { return cachedCloudId }
        guard let client else { throw JiraError.unauthorized }
        let id = try await client.cloudId()
        cachedCloudId = id
        return id
    }

    // MARK: - Launch

    /// Loads saved accounts and signs back in to the last active one.
    func restore() async {
        guard case .restoring = state else { return }
        await accounts.load()
        guard let account = accounts.account(id: accounts.activeAccountID) else {
            state = .signedOut
            return
        }
        guard !account.tokenRejected else {
            notice = SignInError.tokenRejected(account.label).localizedDescription
            state = .signedOut
            return
        }
        do {
            try await signIn(to: account)
        } catch let error as SignInError {
            notice = error.localizedDescription
            state = .signedOut
        } catch {
            notice = "Couldn't sign in to \(account.label) automatically. \(error.localizedDescription)"
            state = .signedOut
        }
    }

    // MARK: - Sign in

    /// New credentials from the form: verified first, then saved and used.
    @discardableResult
    func addAccount(site: String, email: String, apiToken: String) async throws -> SavedAccount {
        let credentials = try Self.makeCredentials(site: site, email: email, apiToken: apiToken)
        let client = JiraClient(credentials: credentials)
        let user = try await client.myself()
        let saved = try await accounts.upsert(credentials: credentials, user: user)
        activate(saved, client: client, user: user)
        return saved
    }

    /// Signs in with a saved account. A 401 flags the account instead of deleting it.
    func signIn(to account: SavedAccount) async throws {
        let client = JiraClient(credentials: account.credentials)
        do {
            let user = try await client.myself()
            let updated = try await accounts.recordSuccess(id: account.id, user: user)
            activate(updated, client: client, user: user)
        } catch JiraError.unauthorized {
            try? await accounts.markRejected(id: account.id)
            throw SignInError.tokenRejected(account.label)
        }
    }

    // MARK: - Edit / delete

    /// Verifies edited details before saving. A blank token keeps the saved one.
    func updateAccount(id: UUID, site: String, email: String, apiToken: String) async throws {
        guard let existing = accounts.account(id: id) else { throw AccountStore.AccountError.missing }
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? existing.credentials.apiToken
            : apiToken
        let credentials = try Self.makeCredentials(site: site, email: email, apiToken: token)
        let client = JiraClient(credentials: credentials)
        let user = try await client.myself()
        let updated = try await accounts.update(id: id, credentials: credentials, user: user)
        if currentAccountID == id {
            activate(updated, client: client, user: user)
        }
        if notice != nil, !accounts.accounts.contains(where: \.tokenRejected) { notice = nil }
    }

    func deleteAccount(id: UUID) async throws {
        try await accounts.delete(id: id)
        AccountDefaults.remove(for: id)
        if currentAccountID == id { signOut() }
    }

    /// Returns to the account picker. Saved accounts are kept.
    func signOut() {
        client = nil
        currentAccountID = nil
        cachedCloudId = nil
        accounts.setActive(nil)
        state = .signedOut
    }

    // MARK: - Private

    private func activate(_ account: SavedAccount, client: JiraClient, user: JiraUser) {
        self.client = client
        currentAccountID = account.id
        cachedCloudId = nil
        accounts.setActive(account.id)
        notice = nil
        state = .signedIn(user)
    }

    static func makeCredentials(site: String, email: String, apiToken: String) throws -> JiraCredentials {
        guard let siteURL = JiraSite.normalize(site) else { throw SignInError.invalidSite }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else { throw SignInError.missingFields }
        return JiraCredentials(siteURL: siteURL, email: trimmedEmail, apiToken: trimmedToken)
    }

    enum SignInError: LocalizedError, Equatable {
        case invalidSite
        case missingFields
        case tokenRejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidSite: return "Enter a valid Jira site, like acme.atlassian.net."
            case .missingFields: return "Email and API token are required."
            case .tokenRejected(let label): return "Jira rejected the saved API token for \(label). Edit the account to enter a new one."
            }
        }
    }
}

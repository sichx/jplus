import Foundation
import Observation

/// Each Jira account has its own GitHub connection. Secrets are saved only in the Keychain.
@Observable
final class GitHubStore {
    private(set) var accountID: UUID?
    private(set) var connection: GitHubConnection?
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private var loadID = UUID()

    func load(for id: UUID?) async {
        if accountID == id && isLoaded { return }
        let requestID = UUID()
        loadID = requestID
        accountID = id
        connection = nil
        loadError = nil
        isLoaded = false
        guard let id else { isLoaded = true; return }
        let keychain = Self.keychain(for: id)
        do {
            let data = try await Task.detached { try keychain.load() }.value
            guard loadID == requestID else { return }
            connection = try data.map { try JSONDecoder().decode(GitHubConnection.self, from: $0) }
        } catch {
            guard loadID == requestID else { return }
            loadError = error.localizedDescription
        }
        if loadID == requestID { isLoaded = true }
    }

    func connect(organizationURL: String, token: String, for id: UUID) async throws {
        guard accountID == id, isLoaded else { throw CancellationError() }
        let organization = try GitHubOrganization(url: organizationURL)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedToken = connection?.organization == organization ? connection?.token : nil
        let credential = trimmed.isEmpty ? (savedToken ?? "") : trimmed
        guard !credential.isEmpty else { throw GitHubError.missingToken }
        let client = GitHubClient(organization: organization, token: credential)
        _ = try await client.repositories()
        try Task.checkCancellation()
        guard accountID == id else { throw CancellationError() }
        let connection = GitHubConnection(organization: organization, token: credential)
        let data = try JSONEncoder().encode(connection)
        let keychain = Self.keychain(for: id)
        try await Task.detached { try keychain.save(data) }.value
        guard accountID == id else { return }
        self.connection = connection
        loadError = nil
    }

    func disconnect(for id: UUID) async throws {
        guard accountID == id else { throw CancellationError() }
        try await Self.removeSavedConnection(for: id)
        guard accountID == id else { return }
        connection = nil
        loadError = nil
    }

    static func removeSavedConnection(for id: UUID) async throws {
        let keychain = keychain(for: id)
        try await Task.detached { try keychain.delete() }.value
    }

    func savedBase(for repository: GitHubRepository, accountID: UUID) -> String? {
        preferences(for: accountID).savedBase(for: repository)
    }

    func rememberBase(_ branch: String, for repository: GitHubRepository, accountID: UUID) {
        preferences(for: accountID).rememberBase(branch, for: repository)
    }

    func preferredRepository(in organization: GitHubOrganization, available: [GitHubRepository], accountID: UUID) -> GitHubRepository? {
        preferences(for: accountID).preferredRepository(in: organization, available: available)
    }

    func rememberRepository(_ repository: GitHubRepository, accountID: UUID) {
        preferences(for: accountID).rememberRepository(repository)
    }

    private func preferences(for id: UUID) -> GitHubPreferences {
        GitHubPreferences(defaults: AccountDefaults.store(for: id))
    }

    private static func keychain(for id: UUID) -> KeychainStore {
        KeychainStore(service: "com.hannagrove.jplus.mac", account: "github-connection-\(id.uuidString)")
    }
}

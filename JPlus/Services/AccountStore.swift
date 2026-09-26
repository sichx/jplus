import Foundation
import Observation

/// Where saved accounts live. The app uses the Keychain; tests use memory.
protocol AccountPersistence: Sendable {
    func loadAccounts() async throws -> [SavedAccount]
    func saveAccounts(_ accounts: [SavedAccount]) async throws
    /// Single-login item written by earlier builds, if any.
    func loadLegacyCredentials() async -> JiraCredentials?
    func deleteLegacyCredentials() async
}

nonisolated struct KeychainAccountPersistence: AccountPersistence {
    private let accountsItem = KeychainStore(service: "co.interactivelabs.jplus", account: "jira-accounts")
    private let legacyItem = KeychainStore(service: "co.interactivelabs.jplus", account: "jira-credentials")

    func loadAccounts() async throws -> [SavedAccount] {
        let item = accountsItem
        guard let data = try await Task.detached(operation: { try item.load() }).value else { return [] }
        return try JSONDecoder().decode([SavedAccount].self, from: data)
    }

    func saveAccounts(_ accounts: [SavedAccount]) async throws {
        let item = accountsItem
        let data = try JSONEncoder().encode(accounts)
        if accounts.isEmpty {
            try await Task.detached { try item.delete() }.value
        } else {
            try await Task.detached { try item.save(data) }.value
        }
    }

    func loadLegacyCredentials() async -> JiraCredentials? {
        let item = legacyItem
        guard let data = await Task.detached(operation: { try? item.load() }).value else { return nil }
        return try? JSONDecoder().decode(JiraCredentials.self, from: data)
    }

    func deleteLegacyCredentials() async {
        let item = legacyItem
        await Task.detached { try? item.delete() }.value
    }
}

/// The list of saved accounts plus which one was last active.
@Observable
final class AccountStore {
    private(set) var accounts: [SavedAccount] = []
    private(set) var activeAccountID: UUID?
    private(set) var isLoaded = false

    private let persistence: AccountPersistence
    private let defaults: UserDefaults
    private static let activeKey = "activeAccountID"

    init(persistence: AccountPersistence, defaults: UserDefaults = .standard) {
        self.persistence = persistence
        self.defaults = defaults
    }

    /// Most recently used first.
    var sortedAccounts: [SavedAccount] {
        accounts.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
    }

    func account(id: UUID?) -> SavedAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func load() async {
        guard !isLoaded else { return }
        accounts = (try? await persistence.loadAccounts()) ?? []
        activeAccountID = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        if account(id: activeAccountID) == nil { activeAccountID = nil }

        // One-time move from the single-login item used by earlier builds.
        if accounts.isEmpty, let legacy = await persistence.loadLegacyCredentials() {
            let migrated = SavedAccount(credentials: legacy, lastUsedAt: .now)
            do {
                try await persistence.saveAccounts([migrated])
                accounts = [migrated]
                setActive(migrated.id)
                AccountDefaults.adoptStandardDefaults(for: migrated.id)
                await persistence.deleteLegacyCredentials()
            } catch {
                // Leave the legacy item in place and try again next launch.
            }
        }
        isLoaded = true
    }

    /// Saves verified credentials. The same user on the same site replaces
    /// the existing entry instead of creating a duplicate.
    @discardableResult
    func upsert(credentials: JiraCredentials, user: JiraUser) async throws -> SavedAccount {
        var updated = accounts
        let saved: SavedAccount
        if let index = updated.firstIndex(where: { $0.isSameLogin(as: credentials, accountId: user.accountId) }) {
            updated[index].credentials = credentials
            updated[index].apply(user)
            updated[index].tokenRejected = false
            updated[index].lastUsedAt = .now
            saved = updated[index]
        } else {
            saved = SavedAccount(credentials: credentials, user: user, lastUsedAt: .now)
            updated.append(saved)
        }
        try await commit(updated)
        return saved
    }

    /// Replaces one entry's credentials after they were verified.
    @discardableResult
    func update(id: UUID, credentials: JiraCredentials, user: JiraUser) async throws -> SavedAccount {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.missing }
        var updated = accounts
        updated[index].credentials = credentials
        updated[index].apply(user)
        updated[index].tokenRejected = false
        // Editing may turn one entry into a duplicate of another; keep the edited one.
        updated.removeAll { $0.id != id && $0.isSameLogin(as: credentials, accountId: user.accountId) }
        try await commit(updated)
        return updated.first { $0.id == id }!
    }

    /// Records a successful sign-in with saved credentials.
    @discardableResult
    func recordSuccess(id: UUID, user: JiraUser) async throws -> SavedAccount {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.missing }
        var updated = accounts
        updated[index].apply(user)
        updated[index].tokenRejected = false
        updated[index].lastUsedAt = .now
        try await commit(updated)
        return updated[index]
    }

    func markRejected(id: UUID) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = accounts
        updated[index].tokenRejected = true
        try await commit(updated)
    }

    func delete(id: UUID) async throws {
        try await commit(accounts.filter { $0.id != id })
        if activeAccountID == id { setActive(nil) }
    }

    func setActive(_ id: UUID?) {
        activeAccountID = id
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeKey)
        } else {
            defaults.removeObject(forKey: Self.activeKey)
        }
    }

    /// Persist first so memory never shows something the Keychain lacks.
    private func commit(_ updated: [SavedAccount]) async throws {
        try await persistence.saveAccounts(updated)
        accounts = updated
    }

    enum AccountError: LocalizedError {
        case missing
        var errorDescription: String? { "That account is no longer saved." }
    }
}

/// Per-account UserDefaults, so recents, search history and project choices
/// don't leak between sites or users.
enum AccountDefaults {
    /// Keys that used to live in the standard defaults before multi-account.
    static let perAccountKeys = [
        "recentIssueKeys", "lastJQL", "jqlHistory", "versionsProjectKey",
        "versionsShowArchived", "newTicketProjectKey", "newTicketIssueTypeName",
    ]

    private static var cache: [UUID: UserDefaults] = [:]

    static func suiteName(for id: UUID) -> String { "co.interactivelabs.jplus.account.\(id.uuidString)" }

    static func store(for id: UUID) -> UserDefaults {
        if let cached = cache[id] { return cached }
        let store = UserDefaults(suiteName: suiteName(for: id)) ?? .standard
        cache[id] = store
        return store
    }

    /// Carries pre-multi-account settings over to the migrated account.
    static func adoptStandardDefaults(for id: UUID) {
        let target = store(for: id)
        for key in perAccountKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                target.set(value, forKey: key)
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func remove(for id: UUID) {
        cache[id] = nil
        UserDefaults.standard.removePersistentDomain(forName: suiteName(for: id))
    }
}

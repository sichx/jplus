import Foundation

/// A Jira login saved on this Mac after it was verified against Jira.
/// Stored (token included) in the Keychain as part of one JSON list.
struct SavedAccount: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var credentials: JiraCredentials
    /// Cached from `/myself` so the picker can show who this is offline.
    var accountId: String?
    var displayName: String?
    var avatarURL: URL?
    var lastUsedAt: Date?
    /// Jira answered 401 with these credentials; the token needs replacing.
    var tokenRejected: Bool

    init(id: UUID = UUID(), credentials: JiraCredentials, user: JiraUser? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.credentials = credentials
        self.lastUsedAt = lastUsedAt
        self.tokenRejected = false
        if let user { apply(user) }
    }

    mutating func apply(_ user: JiraUser) {
        accountId = user.accountId
        displayName = user.displayName
        avatarURL = user.avatarURL
    }

    var label: String { displayName ?? credentials.email }

    var initials: String {
        let source = displayName ?? credentials.email
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// Same Atlassian user on the same site.
    func isSameLogin(as credentials: JiraCredentials, accountId: String) -> Bool {
        self.credentials.siteURL == credentials.siteURL && self.accountId == accountId
    }
}

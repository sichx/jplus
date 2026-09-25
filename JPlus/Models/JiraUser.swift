import Foundation

/// Response shape of `GET /rest/api/3/myself`.
struct JiraUser: Codable, Identifiable, Hashable, Sendable {
    let accountId: String
    let displayName: String
    let emailAddress: String?
    let active: Bool?
    let timeZone: String?
    let locale: String?
    let avatarUrls: [String: URL]?

    var id: String { accountId }

    var avatarURL: URL? {
        avatarUrls?["48x48"] ?? avatarUrls?.values.first
    }

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }
}

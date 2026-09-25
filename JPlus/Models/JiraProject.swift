import Foundation

/// Element of `GET /rest/api/3/project/search`.
struct JiraProject: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let name: String
    let projectTypeKey: String?
    let avatarUrls: [String: URL]?

    var avatarURL: URL? { avatarUrls?["24x24"] ?? avatarUrls?["48x48"] }
}

struct ProjectPage: Decodable, Sendable {
    let values: [JiraProject]
    let isLast: Bool
    let total: Int?
}

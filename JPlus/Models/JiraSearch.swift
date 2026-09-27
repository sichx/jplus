import Foundation

/// Response shape of `GET /rest/api/3/search/jql`.
struct SearchPage<Issue: Decodable>: Decodable {
    let issues: [Issue]
    let isLast: Bool?
    let nextPageToken: String?
}

typealias IssueSearchPage = SearchPage<IssueSummary>

/// Search result with the description, for snippets.
struct IssueSearchDetail: Decodable, Sendable {
    let key: String
    let fields: Fields

    struct Fields: Decodable, Sendable {
        let summary: String
        let status: JiraIssue.Status
        let issueType: JiraIssue.IssueType
        let assignee: JiraUser?
        let updated: Date
        let description: ADFNode?

        enum CodingKeys: String, CodingKey {
            case summary, status, assignee, updated, description
            case issueType = "issuetype"
        }
    }

    static let requestedFields = ["summary", "status", "issuetype", "assignee", "updated", "description"]
}

/// Lightweight issue used in lists; a subset of `JiraIssue`.
struct IssueSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let fields: Fields

    struct Fields: Decodable, Hashable, Sendable {
        let summary: String
        let status: JiraIssue.Status
        let issueType: JiraIssue.IssueType
        let priority: JiraIssue.Priority?
        let assignee: JiraUser?
        let updated: Date

        enum CodingKeys: String, CodingKey {
            case summary, status, priority, assignee, updated
            case issueType = "issuetype"
        }
    }

    static let requestedFields = ["summary", "status", "issuetype", "priority", "assignee", "updated"]
}

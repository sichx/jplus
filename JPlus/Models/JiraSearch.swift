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
        /// From the Development field, when the search asked for it and the
        /// issue has pull requests.
        var pullRequests: PullRequestSummary? = nil

        enum CodingKeys: String, CodingKey {
            case summary, status, priority, assignee, updated
            case issueType = "issuetype"
        }
    }

    static let requestedFields = ["summary", "status", "issuetype", "priority", "assignee", "updated"]
}

// In an extension, so the memberwise init stays.
extension IssueSummary.Fields {
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        status = try container.decode(JiraIssue.Status.self, forKey: .status)
        issueType = try container.decode(JiraIssue.IssueType.self, forKey: .issueType)
        priority = try container.decodeIfPresent(JiraIssue.Priority.self, forKey: .priority)
        assignee = try container.decodeIfPresent(JiraUser.self, forKey: .assignee)
        updated = try container.decode(Date.self, forKey: .updated)
        // The Development field's id differs by site, and it's the only
        // custom field these searches ask for.
        let custom = try decoder.container(keyedBy: AnyKey.self)
        pullRequests = custom.allKeys
            .filter { $0.stringValue.hasPrefix("customfield_") }
            .lazy
            .compactMap { try? custom.decodeIfPresent(String.self, forKey: $0) }
            .compactMap(PullRequestSummary.init(developmentField:))
            .first
    }
}

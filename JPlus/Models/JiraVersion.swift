import Foundation

/// Element of `GET /rest/api/3/project/{key}/version?expand=issuesstatus`.
struct JiraVersion: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let released: Bool
    let archived: Bool
    let overdue: Bool?
    /// `yyyy-MM-dd`, no time zone. Kept as text and parsed as a local calendar day.
    let startDate: String?
    let releaseDate: String?
    let projectId: Int
    let issuesStatusForFixVersion: IssueStatusCounts?

    struct IssueStatusCounts: Decodable, Hashable, Sendable {
        let unmapped: Int
        let toDo: Int
        let inProgress: Int
        let done: Int

        var total: Int { unmapped + toDo + inProgress + done }
        var doneFraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    var releaseDay: Date? { releaseDate.flatMap(JiraDay.parse) }
    var startDay: Date? { startDate.flatMap(JiraDay.parse) }
}

struct VersionPage: Decodable, Sendable {
    let values: [JiraVersion]
    let isLast: Bool
    let total: Int?
}

/// Parses Jira's date-only fields (`2026-09-30`) as local calendar days.
nonisolated enum JiraDay {
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? { formatter.date(from: raw) }
}

/// The rich "Version highlights" block Jira shows on a release page. It is
/// not in the REST API; it comes from Jira's GraphQL gateway.
struct VersionHighlights: Hashable, Sendable {
    let versionId: String
    let title: String?
    let content: ADFNode?
    let description: String?

    var hasContent: Bool { !(content?.children.isEmpty ?? true) }

    /// One-paragraph plain-text excerpt for list rows.
    var excerpt: String? {
        let text = (content?.plainText ?? description ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}

/// Wire shape of the `versionsForProject` GraphQL query.
struct VersionHighlightsPage: Decodable, Sendable {
    let data: DataField?
    let errors: [GraphQLError]?

    struct DataField: Decodable, Sendable {
        let jira: Jira
        struct Jira: Decodable, Sendable {
            let versionsForProject: Connection?
        }
    }

    struct Connection: Decodable, Sendable {
        let pageInfo: PageInfo
        let edges: [Edge]
        struct PageInfo: Decodable, Sendable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        struct Edge: Decodable, Sendable {
            let node: Node
        }
        struct Node: Decodable, Sendable {
            let versionId: String
            let name: String?
            let description: String?
            let richTextSection: RichTextSection?
        }
        struct RichTextSection: Decodable, Sendable {
            let title: String?
            let content: Content?
            struct Content: Decodable, Sendable {
                let json: ADFNode?
            }
        }
    }

    struct GraphQLError: Decodable, Sendable {
        let message: String
    }
}

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

    var isOverdue: Bool {
        if let overdue { return overdue }
        guard !released, let day = releaseDay else { return false }
        return day < Calendar.current.startOfDay(for: .now)
    }
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

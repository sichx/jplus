import Foundation

/// Branches and pull requests linked to an issue, as in Jira's Development
/// panel. They come from code hosts such as GitHub for Jira.
struct IssueDevelopment: Sendable, Equatable {
    var branches: [Branch] = []
    var pullRequests: [PullRequest] = []

    var isEmpty: Bool { branches.isEmpty && pullRequests.isEmpty }

    struct Branch: Identifiable, Hashable, Sendable {
        var id: String { (url?.absoluteString ?? "") + "|" + repositoryName + "|" + name }
        let name: String
        let url: URL?
        let repositoryName: String
    }

    struct PullRequest: Identifiable, Hashable, Sendable {
        enum Status: String, Sendable {
            case open, merged, declined, draft, unknown

            init(raw: String?) {
                switch raw?.uppercased() {
                case "OPEN": self = .open
                case "MERGED": self = .merged
                case "DECLINED", "CLOSED": self = .declined
                case "DRAFT": self = .draft
                default: self = .unknown
                }
            }

            var title: String {
                switch self {
                case .open: "Open"
                case .merged: "Merged"
                case .declined: "Closed"
                case .draft: "Draft"
                case .unknown: "Unknown"
                }
            }
        }

        var id: String { (url?.absoluteString ?? "") + "|" + repositoryName + "|" + number }
        /// "#123".
        let number: String
        let title: String
        let url: URL?
        let status: Status
        let repositoryName: String
        let sourceBranch: String?
        let lastUpdate: Date?
    }
}

/// Wire shape of `/rest/dev-status/latest/issue/summary`.
nonisolated struct DevStatusSummaryResponse: Decodable, Sendable {
    let summary: Summary?

    nonisolated struct Summary: Decodable, Sendable {
        let branch: Item?
        let pullrequest: Item?
        let repository: Item?
    }

    nonisolated struct Item: Decodable, Sendable {
        let byInstanceType: [String: Instance]?
    }

    nonisolated struct Instance: Decodable, Sendable {
        let count: Int?
    }
}

/// Wire shape of `/rest/dev-status/latest/issue/detail`.
nonisolated struct DevStatusDetailResponse: Decodable, Sendable {
    let detail: [Detail]?

    nonisolated struct Detail: Decodable, Sendable {
        let branches: [Branch]?
        let pullRequests: [PullRequest]?
    }

    nonisolated struct Branch: Decodable, Sendable {
        let name: String?
        let url: String?
        let repository: Repository?
    }

    nonisolated struct Repository: Decodable, Sendable {
        let name: String?
    }

    nonisolated struct PullRequest: Decodable, Sendable {
        let id: String?
        let name: String?
        let url: String?
        let status: String?
        let lastUpdate: String?
        let repositoryName: String?
        let source: Ref?
    }

    nonisolated struct Ref: Decodable, Sendable {
        let branch: String?
    }
}

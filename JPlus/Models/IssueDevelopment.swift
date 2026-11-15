import Foundation

/// Branches and pull requests linked to an issue, as in Jira's Development
/// panel. They come from code hosts such as GitHub for Jira.
nonisolated struct IssueDevelopment: Sendable, Equatable {
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

/// The pull-request part of Jira's Development field, as returned in a
/// search: how many pull requests an issue has and their overall state.
/// Jira gives one state (the most active one) and how many are in it,
/// not a count for every state.
nonisolated struct PullRequestSummary: Hashable, Sendable {
    let state: IssueDevelopment.PullRequest.Status
    let count: Int
    /// How many of `count` are in `state`.
    let stateCount: Int

    /// Open first, then draft, merged and closed; for sorting.
    var rank: Int {
        switch state {
        case .open: 0
        case .draft: 1
        case .merged: 2
        case .declined: 3
        case .unknown: 4
        }
    }

    /// "2 merged pull requests", or "3 pull requests, 1 open".
    var description: String {
        let stateWord = state.title.lowercased()
        if stateCount == count {
            return "\(count) \(stateWord) pull request\(count == 1 ? "" : "s")"
        }
        return "\(count) pull requests, \(stateCount) \(stateWord)"
    }

    /// Reads the Development field's value, which looks like
    /// `{pullrequest={dataType=pullrequest, state=OPEN, stateCount=1}, json={…}}`.
    /// Nil when the issue has no pull requests.
    init?(developmentField raw: String) {
        if let parsed = Self.fromJSON(raw) ?? Self.fromText(raw) {
            self = parsed
        } else {
            return nil
        }
    }

    private init(state: IssueDevelopment.PullRequest.Status, count: Int, stateCount: Int) {
        self.state = state
        self.count = count
        self.stateCount = stateCount
    }

    /// The `json={…}` part, which has the total as well as the state.
    private static func fromJSON(_ raw: String) -> PullRequestSummary? {
        guard let start = raw.range(of: "json=") else { return nil }
        var json = raw[start.upperBound...]
        // The JSON is the last value in the outer braces.
        if json.hasSuffix("}") { json = json.dropLast() }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedValue"] as? [String: Any],
              let summary = cached["summary"] as? [String: Any],
              let pullRequests = summary["pullrequest"] as? [String: Any],
              let overall = pullRequests["overall"] as? [String: Any],
              let count = overall["count"] as? Int, count > 0
        else { return nil }
        let stateCount = overall["stateCount"] as? Int ?? count
        return PullRequestSummary(state: .init(raw: overall["state"] as? String), count: count, stateCount: stateCount)
    }

    /// The `pullrequest={…}` part, for when the JSON is missing.
    private static func fromText(_ raw: String) -> PullRequestSummary? {
        guard let match = raw.firstMatch(of: /pullrequest=\{[^}]*state=(\w+)[^}]*stateCount=(\d+)/),
              let stateCount = Int(match.2), stateCount > 0
        else { return nil }
        return PullRequestSummary(state: .init(raw: String(match.1)), count: stateCount, stateCount: stateCount)
    }
}

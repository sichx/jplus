import Foundation

/// Response shape of `GET /rest/api/3/issue/{key}` (subset of fields).
struct JiraIssue: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let fields: Fields

    struct Fields: Decodable, Hashable, Sendable {
        let summary: String
        let description: ADFNode?
        let status: Status
        let issueType: IssueType
        let priority: Priority?
        let assignee: JiraUser?
        let reporter: JiraUser?
        let created: Date
        let updated: Date
        let labels: [String]
        let components: [Named]
        let fixVersions: [VersionRef]
        let parent: IssueRef?
        let subtasks: [IssueRef]?
        let comment: CommentPage?
        let attachments: [Attachment]?

        enum CodingKeys: String, CodingKey {
            case summary, description, status, priority, assignee, reporter
            case created, updated, labels, components, fixVersions, parent, subtasks, comment
            case issueType = "issuetype"
            case attachments = "attachment"
        }
    }

    struct Status: Decodable, Hashable, Sendable {
        let name: String
        let statusCategory: StatusCategory?

        /// True for statuses in Jira's Done category, such as Done and Won't Do.
        var isDone: Bool { statusCategory?.key == "done" }
    }

    struct StatusCategory: Decodable, Hashable, Sendable {
        /// "new", "indeterminate", or "done"
        let key: String
        let colorName: String?
    }

    struct IssueType: Decodable, Hashable, Sendable {
        let name: String
        let subtask: Bool?
        /// 1 for epics, 0 for standard issues, -1 for sub-tasks.
        let hierarchyLevel: Int?

        /// Epics and above, whose children are issues rather than sub-tasks.
        var isEpicLevel: Bool {
            (hierarchyLevel ?? 0) > 0 || name.caseInsensitiveCompare("Epic") == .orderedSame
        }
    }

    struct Priority: Decodable, Hashable, Sendable {
        let id: String?
        let name: String
    }

    struct Named: Decodable, Hashable, Sendable {
        let name: String
    }

    /// A fix version as embedded in an issue.
    struct VersionRef: Decodable, Hashable, Sendable {
        let id: String
        let name: String
    }

    /// The project part of the key: "VPE" for "VPE-5553".
    var projectKey: String { String(key.prefix { $0 != "-" }) }

    /// Another issue as Jira embeds it in this one: the parent, or a sub-task.
    struct IssueRef: Decodable, Hashable, Sendable {
        let key: String
        let fields: Fields?

        struct Fields: Decodable, Hashable, Sendable {
            let summary: String?
            let status: Status?
            let issueType: IssueType?

            enum CodingKeys: String, CodingKey {
                case summary, status
                case issueType = "issuetype"
            }
        }
    }

    struct CommentPage: Decodable, Hashable, Sendable {
        let comments: [Comment]
        let total: Int
    }

    struct Comment: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let author: JiraUser?
        let body: ADFNode?
        let created: Date
        let updated: Date
        /// The comment this one replies to. Only the comment list sends it
        /// (`GET …/issue/{key}/comment`), not the comments embedded in an issue.
        let parentId: String?

        enum CodingKeys: String, CodingKey {
            case id, author, body, created, updated, parentId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            author = try container.decodeIfPresent(JiraUser.self, forKey: .author)
            body = try container.decodeIfPresent(ADFNode.self, forKey: .body)
            created = try container.decode(Date.self, forKey: .created)
            updated = try container.decode(Date.self, forKey: .updated)
            // Jira sends ids as strings but this one as a number.
            if let text = try? container.decode(String.self, forKey: .parentId) {
                parentId = text
            } else {
                parentId = (try? container.decode(Int.self, forKey: .parentId)).map(String.init)
            }
        }
    }

    /// A top-level comment with the replies under it, oldest first.
    struct CommentThread: Identifiable, Hashable, Sendable {
        let root: Comment
        let replies: [Comment]

        var id: String { root.id }

        /// Groups a flat comment list into threads, keeping its order. A reply
        /// whose parent isn't in the list starts a thread of its own.
        static func group(_ comments: [Comment]) -> [CommentThread] {
            let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            /// Follows replies-to-replies up to the comment that started the thread.
            func rootID(of comment: Comment) -> String {
                var current = comment
                var seen: Set<String> = [current.id]
                while let parentID = current.parentId, let parent = byID[parentID], seen.insert(parentID).inserted {
                    current = parent
                }
                return current.id
            }
            var replies: [String: [Comment]] = [:]
            var roots: [Comment] = []
            for comment in comments {
                let root = rootID(of: comment)
                if root == comment.id {
                    roots.append(comment)
                } else {
                    replies[root, default: []].append(comment)
                }
            }
            return roots.map { CommentThread(root: $0, replies: replies[$0.id] ?? []) }
        }
    }

    /// A file attached to the issue, including images pasted into the
    /// description or a comment.
    struct Attachment: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let filename: String
        let mimeType: String?
        let size: Int?
        let created: Date?

        var isImage: Bool { mimeType?.hasPrefix("image/") == true }
    }

    /// Field list requested from the API; keep in sync with `Fields`.
    static let requestedFields = [
        "summary", "description", "status", "issuetype", "priority", "assignee", "reporter",
        "created", "updated", "labels", "components", "fixVersions", "parent", "subtasks", "comment", "attachment",
    ]
}

/// A move allowed by the issue's workflow, from `GET …/transitions`.
/// Its name can differ from the status it leads to.
struct JiraTransition: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let to: JiraIssue.Status
}

enum IssueKey {
    /// Normalizes user input into a Jira issue key, or nil if it can't be one.
    /// Accepts "vpe-5555", " VPE-5555 ", and browse URLs like
    /// "https://acme.atlassian.net/browse/VPE-5555?focusedCommentId=1".
    static func parse(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "/browse/", options: .caseInsensitive) {
            text = String(text[range.upperBound...])
            if let end = text.firstIndex(where: { "/?#".contains($0) }) {
                text = String(text[..<end])
            }
        }
        text = text.uppercased()
        guard text.wholeMatch(of: /[A-Z][A-Z0-9_]*-[0-9]+/) != nil else { return nil }
        return text
    }
}

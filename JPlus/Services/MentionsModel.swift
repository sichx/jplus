import Foundation
import Observation

/// One place where the signed-in user was @-mentioned.
struct Mention: Identifiable, Hashable, Sendable {
    enum Place: Hashable, Sendable {
        case description
        case comment(id: String)
    }

    let id: String
    let issueKey: String
    let issueSummary: String
    let status: JiraIssue.Status
    let typeName: String
    let place: Place
    /// Who wrote the text containing the mention.
    let author: JiraUser?
    /// When the mention was written: the comment's time, or the issue's
    /// creation time for mentions in the description.
    let date: Date
    /// The paragraph or list item around the mention, as plain text.
    let excerpt: String
}

/// Issue fields needed to find mentions.
struct MentionSourceIssue: Decodable, Sendable {
    let key: String
    let fields: Fields

    struct Fields: Decodable, Sendable {
        let summary: String
        let status: JiraIssue.Status
        let issueType: JiraIssue.IssueType
        let created: Date
        let updated: Date
        let reporter: JiraUser?
        let creator: JiraUser?
        let description: ADFNode?
        let comment: JiraIssue.CommentPage?

        enum CodingKeys: String, CodingKey {
            case summary, status, created, updated, reporter, creator, description, comment
            case issueType = "issuetype"
        }
    }

    static let requestedFields = ["summary", "status", "issuetype", "created", "updated", "reporter", "creator", "description", "comment"]
}

/// Finds @-mentions of the current user in descriptions and comments.
@Observable
final class MentionsModel {
    private(set) var mentions: [Mention] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var canLoadMore = false

    private var nextPageToken: String?
    private var generation = 0

    /// Issues whose text mentions the current user, most recently updated
    /// first. A mention can't be newer than its issue's last update, so
    /// paging in this order keeps the newest mentions complete.
    static let jql = "text ~ currentUser() ORDER BY updated DESC"
    private static let pageSize = 50

    func reload(accountID: String, client: JiraClient) async {
        generation += 1
        mentions = []
        nextPageToken = nil
        canLoadMore = false
        errorMessage = nil
        await loadPage(accountID: accountID, client: client, generation: generation)
        hasLoaded = true
    }

    func loadMore(accountID: String, client: JiraClient) async {
        guard canLoadMore, !isLoading else { return }
        await loadPage(accountID: accountID, client: client, generation: generation)
    }

    private func loadPage(accountID: String, client: JiraClient, generation: Int) async {
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let page: SearchPage<MentionSourceIssue> = try await client.search(
                jql: Self.jql, fields: MentionSourceIssue.requestedFields,
                maxResults: Self.pageSize, nextPageToken: nextPageToken
            )
            var found: [Mention] = []
            for issue in page.issues {
                var comments = issue.fields.comment?.comments ?? []
                // Search results can carry only part of a long discussion.
                if let total = issue.fields.comment?.total, total > comments.count {
                    comments = (try? await client.allComments(issueKey: issue.key)) ?? comments
                }
                found += Self.mentions(in: issue, comments: comments, accountID: accountID)
            }
            guard generation == self.generation else { return }
            var byID = Dictionary(mentions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for mention in found { byID[mention.id] = mention }
            mentions = byID.values.sorted { $0.date > $1.date }
            nextPageToken = page.nextPageToken
            canLoadMore = page.nextPageToken != nil && page.isLast != true
        } catch {
            guard generation == self.generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Extraction

    nonisolated static func mentions(in issue: MentionSourceIssue, comments: [JiraIssue.Comment], accountID: String) -> [Mention] {
        let fields = issue.fields
        var result: [Mention] = []

        if let description = fields.description {
            for (index, excerpt) in excerpts(in: description, accountID: accountID).enumerated() {
                result.append(Mention(
                    id: "\(issue.key)#description#\(index)", issueKey: issue.key, issueSummary: fields.summary,
                    status: fields.status, typeName: fields.issueType.name, place: .description,
                    author: fields.reporter ?? fields.creator, date: fields.created, excerpt: excerpt
                ))
            }
        }
        for comment in comments {
            guard let body = comment.body else { continue }
            for (index, excerpt) in excerpts(in: body, accountID: accountID).enumerated() {
                result.append(Mention(
                    id: "\(issue.key)#comment-\(comment.id)#\(index)", issueKey: issue.key, issueSummary: fields.summary,
                    status: fields.status, typeName: fields.issueType.name, place: .comment(id: comment.id),
                    author: comment.author, date: comment.created, excerpt: excerpt
                ))
            }
        }
        return result
    }

    /// Text of each paragraph-level block that mentions `accountID` (once
    /// per block), trimmed so the mention itself is always included.
    nonisolated static func excerpts(in document: ADFNode, accountID: String) -> [String] {
        let blockTypes: Set<String> = ["paragraph", "heading", "listItem", "taskItem", "tableCell", "tableHeader", "blockquote", "panel"]
        var excerpts: [String] = []

        func isMe(_ node: ADFNode) -> Bool {
            guard node.type == "mention", let id = node.attr("id") else { return false }
            return id == accountID || id.hasSuffix(":" + accountID) || id.hasSuffix(accountID)
        }
        func firstMention(in node: ADFNode) -> ADFNode? {
            if isMe(node) { return node }
            for child in node.children { if let found = firstMention(in: child) { return found } }
            return nil
        }
        func mentionsMe(_ node: ADFNode) -> Bool { firstMention(in: node) != nil }
        func collapse(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        func walk(_ node: ADFNode) {
            // Use the innermost block that contains the mention.
            if blockTypes.contains(node.type), mentionsMe(node),
               !node.children.contains(where: { blockTypes.contains($0.type) && mentionsMe($0) }) {
                let mentionText = firstMention(in: node)?.attr("text")
                var text = collapse(node.plainText)
                // A bare "cc: @name" line says little; use the whole text instead.
                if text.count < 60 { text = collapse(document.plainText) }
                let excerpt = clip(text, around: mentionText)
                if !excerpts.contains(excerpt) { excerpts.append(excerpt) }
                return
            }
            node.children.forEach(walk)
        }
        walk(document)

        // A mention outside any block (unusual) still counts.
        if excerpts.isEmpty, let mention = firstMention(in: document) {
            excerpts.append(clip(collapse(document.plainText), around: mention.attr("text")))
        }
        return excerpts
    }

    /// Shortens `text` without ever cutting off `mention`: short text is
    /// kept whole; otherwise the start is kept for context and, when the
    /// mention comes later, a window around it is added after "…".
    nonisolated static func clip(_ text: String, around mention: String?) -> String {
        let fullLimit = 320      // shorter than this: show everything
        let headLength = 180     // context kept from the start
        let before = 60          // characters shown before the mention
        let after = 90           // characters shown after the mention

        guard text.count > fullLimit else { return text }

        guard let mention, let range = text.range(of: mention, options: .caseInsensitive) else {
            return trimEnd(text, to: 280) + " …"
        }
        let mentionStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let mentionEnd = text.distance(from: text.startIndex, to: range.upperBound)

        // Mention near the start: one continuous excerpt through it.
        if mentionStart <= headLength + before {
            let end = min(text.count, max(280, mentionEnd + after))
            return end >= text.count ? text : trimEnd(text, to: end) + " …"
        }

        // Mention further in: opening, then a window around the mention.
        let head = trimEnd(text, to: headLength)
        let windowStart = wordStart(in: text, near: mentionStart - before)
        let windowEnd = min(text.count, mentionEnd + after)
        let startIndex = text.index(text.startIndex, offsetBy: windowStart)
        var window = String(text[startIndex...])
        let reachesEnd = windowEnd >= text.count
        if !reachesEnd { window = trimEnd(window, to: windowEnd - windowStart) }
        return head + " … " + window + (reachesEnd ? "" : " …")
    }

    /// First `length` characters, backed up to the last space so words stay whole.
    nonisolated private static func trimEnd(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        let cut = String(text.prefix(length))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > length / 2 {
            return String(cut[..<space])
        }
        return cut
    }

    /// Offset of the start of the word at or after `offset`.
    nonisolated private static func wordStart(in text: String, near offset: Int) -> Int {
        let clamped = max(0, min(offset, text.count))
        guard clamped > 0 else { return 0 }
        var index = text.index(text.startIndex, offsetBy: clamped)
        while index < text.endIndex, text[text.index(before: index)] != " " {
            index = text.index(after: index)
        }
        return text.distance(from: text.startIndex, to: index)
    }
}

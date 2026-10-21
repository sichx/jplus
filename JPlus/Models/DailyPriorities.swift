import Foundation

/// One checkbox on a day's page: a `taskItem` in the page's ADF.
nonisolated struct PriorityItem: Identifiable, Hashable, Sendable {
    /// The task item's `localId`, which Confluence keeps across edits.
    let id: String
    var isDone: Bool
    /// Inline content: text with marks, mentions, issue cards.
    var content: [ADFNode]

    var plainText: String { content.map(\.plainText).joined() }

    /// Ids of the inline comments highlighting this item's text.
    var commentMarkerIDs: Set<String> { Set(content.flatMap(\.inlineCommentIDs)) }

    /// The content without its comment highlights, for a copy on another
    /// page, where those comments don't exist.
    var contentWithoutComments: [ADFNode] { content.map { $0.removingInlineComments() } }

    /// Whether it has text a new comment can hang on, not only cards or mentions.
    var canBeCommentedOn: Bool { ADFNode.taskItem(content, id: id).commentAnchor(forItem: id) != nil }
}

/// A change to a priority while it saves, as the screen shows it then: the
/// item as it will read once saved, or as it read for one being deleted.
nonisolated struct PrioritySave: Hashable, Sendable {
    enum Change: Hashable, Sendable {
        case saving, adding, deleting, moving
    }

    let change: Change
    let text: String
    let isDone: Bool
}

/// The text a new inline comment highlights. Confluence finds it by
/// matching: it's the `index`th (from 0) of `count` copies on the page.
nonisolated struct PriorityCommentAnchor: Hashable, Sendable {
    let text: String
    let index: Int
    let count: Int
}

/// An inline comment on a day's page, with the replies under it.
nonisolated struct PriorityCommentThread: Identifiable, Hashable, Sendable {
    let root: ConfluenceComment
    let replies: [ConfluenceComment]

    var id: String { root.id }
}

/// One day's page under the Daily Priorities folder, named `yyyy-MM-dd`.
nonisolated struct PriorityDay: Identifiable, Hashable, Sendable {
    let pageID: String
    let title: String
    let day: Date
    var version: Int
    var document: ADFNode
    let webURL: URL

    var id: String { pageID }
    var items: [PriorityItem] { document.taskItems }
    var openCount: Int { items.filter { !$0.isDone }.count }

    init(page: ConfluencePage, day: Date, siteURL: URL) {
        pageID = page.id
        title = page.title
        self.day = day
        version = page.version.number
        document = page.document
        webURL = page.webURL(on: siteURL)
    }
}

/// A day page found under the folder, before its body is loaded.
nonisolated struct PriorityDayRef: Identifiable, Hashable, Sendable {
    let pageID: String
    let title: String
    let day: Date
    let monthFolderID: String

    var id: String { pageID }

    /// Works for any page id, without knowing the space key.
    func webURL(on siteURL: URL) -> URL {
        var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)!
        components.path = "/wiki/pages/viewpage.action"
        components.queryItems = [URLQueryItem(name: "pageId", value: pageID)]
        return components.url!
    }
}

/// How days and months are named in Confluence: `2026-10` folders holding
/// `2026-10-07` pages, in the Mac's calendar and time zone.
nonisolated enum PriorityNaming {
    static func monthTitle(for day: Date) -> String { month.string(from: day) }
    static func dayTitle(for day: Date) -> String { date.string(from: day) }
    static func day(fromTitle title: String) -> Date? { date.date(from: title) }
    static func isMonthTitle(_ title: String) -> Bool { title.wholeMatch(of: /\d{4}-\d{2}/) != nil }
    static func isDayTitle(_ title: String) -> Bool { title.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil }

    /// The folder id in a link like `…/wiki/spaces/VPE1/folder/2366275586/Daily+Priorities`,
    /// or a bare id.
    static func folderID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: /\d+/) != nil { return text }
        guard let match = text.firstMatch(of: /\/folder\/(\d+)/) else { return nil }
        return String(match.1)
    }

    /// The team's convention: a "Daily Priorities" folder inside a "Mobile App"
    /// (or "Mobile Apps") folder. Found by title search, so the app needs no
    /// setup on a site that follows it.
    static let folderTitle = "Daily Priorities"
    static let parentFolderTitle = "Mobile App"

    /// Whether a folder title is the expected parent, ignoring case, spacing
    /// and a plural s.
    static func isParentFolderTitle(_ title: String) -> Bool {
        var normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if normalized.hasSuffix("s") { normalized.removeLast() }
        return normalized == parentFolderTitle.lowercased()
    }

    /// The one "Daily Priorities" folder under a "Mobile App(s)" folder, or nil
    /// when there is none or more than one, in which case the user picks.
    static func findFolder(using client: JiraClient) async throws -> ConfluenceFolder? {
        let results = try await client.confluenceSearch(cql: "type = folder and title = \"\(folderTitle)\"")
        var matches: [ConfluenceFolder] = []
        for result in results {
            guard let content = result.content, content.type == "folder",
                  (content.title ?? result.title ?? "").caseInsensitiveCompare(folderTitle) == .orderedSame
            else { continue }
            let folder = try await client.confluenceFolder(id: content.id)
            guard folder.parentType == "folder", let parentID = folder.parentId else { continue }
            let parent = try await client.confluenceFolder(id: parentID)
            if isParentFolderTitle(parent.title) { matches.append(folder) }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static let month: DateFormatter = formatter("yyyy-MM")
    private static let date: DateFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

nonisolated extension ADFNode {
    /// Every task item in the document, in reading order.
    var taskItems: [PriorityItem] {
        if type == "taskItem", let id = attr("localId") {
            return [PriorityItem(id: id, isDone: attr("state") == "DONE", content: children)]
        }
        return children.flatMap(\.taskItems)
    }

    /// A copy with each task item replaced by `transform`'s result, or
    /// removed when it returns nil. Task lists left empty go too, since the
    /// schema doesn't allow them.
    func replacingTaskItems(_ transform: (PriorityItem, ADFNode) -> ADFNode?) -> ADFNode {
        guard let content else { return self }
        var replaced: [ADFNode] = []
        for child in content {
            if child.type == "taskItem", let id = child.attr("localId") {
                let item = PriorityItem(id: id, isDone: child.attr("state") == "DONE", content: child.children)
                if let node = transform(item, child) { replaced.append(node) }
            } else {
                let node = child.replacingTaskItems(transform)
                if node.type == "taskList", node.children.isEmpty { continue }
                replaced.append(node)
            }
        }
        return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: replaced)
    }

    /// A copy with the items appended to the document's last top-level task
    /// list, or to a new one at the end.
    func appendingTaskItem(_ items: [ADFNode]) -> ADFNode {
        var blocks = children
        if let index = blocks.lastIndex(where: { $0.type == "taskList" }) {
            let list = blocks[index]
            blocks[index] = ADFNode(type: "taskList", attrs: list.attrs, content: list.children + items)
        } else {
            blocks.append(ADFNode.taskList(items))
        }
        return ADFNode(type: type, attrs: attrs, content: blocks)
    }

    /// A copy with `item` right after the task item `id`, in the same list;
    /// nil when there's no such item.
    func insertingTaskItem(_ item: ADFNode, after id: String) -> ADFNode? {
        guard var blocks = content else { return nil }
        for (index, child) in blocks.enumerated() {
            if child.type == "taskItem", child.attr("localId") == id {
                blocks.insert(item, at: index + 1)
            } else if let inserted = child.insertingTaskItem(item, after: id) {
                blocks[index] = inserted
            } else {
                continue
            }
            return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: blocks)
        }
        return nil
    }

    /// Ids of the inline comments whose highlight covers part of this node.
    var inlineCommentIDs: [String] {
        let own = (marks ?? []).filter(\.isInlineComment).compactMap { $0.attr("id") }
        return own + children.flatMap(\.inlineCommentIDs)
    }

    /// Where a new comment on the task item `id` hangs: its longest run of
    /// text not yet commented on (or one that is, failing that), without
    /// the spaces and punctuation around it. Nil when the item has no text.
    func commentAnchor(forItem id: String) -> PriorityCommentAnchor? {
        let runs = textRuns(in: nil)
        let candidates = runs.indices.compactMap { index -> (run: Int, range: Range<String.Index>)? in
            let run = runs[index]
            guard run.itemID == id,
                  let first = run.text.firstIndex(where: { !$0.isWhitespace && !$0.isPunctuation }),
                  let last = run.text.lastIndex(where: { !$0.isWhitespace && !$0.isPunctuation })
            else { return nil }
            return (index, first..<run.text.index(after: last))
        }
        func preference(_ candidate: (run: Int, range: Range<String.Index>)) -> (Int, Int) {
            (runs[candidate.run].isCommented ? 0 : 1, runs[candidate.run].text[candidate.range].count)
        }
        guard let chosen = candidates.max(by: { preference($0) < preference($1) }) else { return nil }
        let text = String(runs[chosen.run].text[chosen.range])
        let before = runs[..<chosen.run].reduce(0) { $0 + $1.text.ranges(of: text).count }
            + runs[chosen.run].text.ranges(of: text).filter { $0.lowerBound < chosen.range.lowerBound }.count
        let count = runs.reduce(0) { $0 + $1.text.ranges(of: text).count }
        return PriorityCommentAnchor(text: text, index: before, count: count)
    }

    /// The document's text nodes in reading order, each with the task item it's in.
    private func textRuns(in itemID: String?) -> [(itemID: String?, text: String, isCommented: Bool)] {
        if type == "text", let text {
            return [(itemID, text, (marks ?? []).contains(where: \.isInlineComment))]
        }
        let itemID = type == "taskItem" ? attr("localId") : itemID
        return children.flatMap { $0.textRuns(in: itemID) }
    }

    /// A copy without inline comment highlights; other marks stay.
    func removingInlineComments() -> ADFNode {
        let kept = marks?.filter { !$0.isInlineComment }
        return ADFNode(type: type, text: text, attrs: attrs, marks: kept?.isEmpty == true ? nil : kept,
                       content: content?.map { $0.removingInlineComments() })
    }

    static func taskList(_ items: [ADFNode]) -> ADFNode {
        ADFNode(type: "taskList", attrs: ["localId": .string(UUID().uuidString.lowercased())], content: items)
    }

    static func taskItem(_ content: [ADFNode], done: Bool = false, id: String = UUID().uuidString.lowercased()) -> ADFNode {
        ADFNode(type: "taskItem", attrs: ["localId": .string(id), "state": .string(done ? "DONE" : "TODO")], content: content)
    }

    /// Typed text as inline nodes: issue keys become cards that open in the
    /// app, web links become links, line breaks become hard breaks, the rest
    /// stays text.
    static func inlineContent(from text: String, siteURL: URL) -> [ADFNode] {
        var nodes: [ADFNode] = []
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if index > 0 { nodes.append(ADFNode(type: "hardBreak")) }
            nodes += lineContent(from: String(line), siteURL: siteURL)
        }
        return nodes
    }

    private static func lineContent(from text: String, siteURL: URL) -> [ADFNode] {
        var nodes: [ADFNode] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { nodes.append(ADFNode(type: "text", text: plain)); plain = "" }
        }
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let token = String(word)
            // Trailing punctuation stays outside the link or card.
            let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
            let trailing = String(token.dropFirst(core.count))
            if !plain.isEmpty || !nodes.isEmpty { plain += " " }
            if core.wholeMatch(of: /[A-Z][A-Z0-9_]*-[0-9]+/) != nil {
                flush()
                nodes.append(ADFNode(type: "inlineCard", attrs: ["url": .string(siteURL.appending(path: "browse/\(core)").absoluteString)]))
                plain = trailing
            } else if core.hasPrefix("http://") || core.hasPrefix("https://"), URL(string: core) != nil {
                flush()
                nodes.append(ADFNode(type: "text", text: core, marks: [ADFMark(type: "link", attrs: ["href": .string(core)])]))
                plain = trailing
            } else {
                plain += token
            }
        }
        flush()
        return nodes
    }
}

nonisolated extension ADFMark {
    /// The highlight an inline comment hangs on.
    var isInlineComment: Bool { type == "annotation" && attr("annotationType") == "inlineComment" }
}

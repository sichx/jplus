import Foundation

/// One checkbox on a day's page: a `taskItem` in the page's ADF.
nonisolated struct PriorityItem: Identifiable, Hashable, Sendable {
    /// The task item's `localId`, which Confluence keeps across edits.
    let id: String
    var isDone: Bool
    /// Inline content: text with marks, mentions, issue cards.
    var content: [ADFNode]

    var plainText: String { content.map(\.plainText).joined() }

    /// The text as it's edited: the plain text, with each link whose text
    /// isn't its address written `[text](address)`, which saving reads back.
    var editableText: String { editedPieces.map(\.edited).joined() }

    /// Where an offset (in UTF-16) in the plain text falls in the editable
    /// text. Inside a written-out link it's inside the brackets; at either
    /// end of the link's text it's outside the whole link.
    func editableOffset(forPlainOffset offset: Int) -> Int {
        var plainStart = 0
        var editedStart = 0
        for piece in editedPieces {
            let length = piece.plain.utf16.count
            if offset <= plainStart + length {
                let inner = offset - plainStart
                if piece.edited == piece.plain || inner == 0 { return editedStart + inner }
                return editedStart + (inner == length ? piece.edited.utf16.count : 1 + inner)
            }
            plainStart += length
            editedStart += piece.edited.utf16.count
        }
        return editedStart
    }

    /// The content a piece at a time, each with its plain text and how it's
    /// edited. A link's text nodes (split where only part is bold, say) make
    /// one piece; one that wouldn't read back as written stays plain text.
    private var editedPieces: [(plain: String, edited: String)] {
        var pieces: [(plain: String, edited: String)] = []
        var link: (href: String, text: String)?
        func endLink() {
            guard let current = link else { return }
            link = nil
            let written = "[\(current.text)](\(current.href))"
            let keeps = current.text != current.href && written.wholeMatch(of: ADFNode.typedLink) != nil
            pieces.append((current.text, keeps ? written : current.text))
        }
        for node in content {
            if node.type == "text", let href = node.marks?.first(where: { $0.type == "link" })?.attr("href") {
                if link?.href == href {
                    link?.text += node.text ?? ""
                } else {
                    endLink()
                    link = (href, node.text ?? "")
                }
            } else {
                endLink()
                pieces.append((node.plainText, node.plainText))
            }
        }
        endLink()
        return pieces
    }

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
        case saving, adding, deleting, moving, addingPhoto, removingPhoto
    }

    let change: Change
    let text: String
    let isDone: Bool
}

/// A photo under a priority. A checkbox item can only hold a line of text,
/// so on the page a photo is an image block (`mediaSingle`) right after the
/// item's list, splitting it when the item isn't the list's last, as
/// Confluence's editor does with an image pasted partway down a checklist.
/// It shows a file attached to the page. Every image block after a list
/// belongs to that list's last item, until anything else comes along.
nonisolated struct PriorityPhoto: Identifiable, Hashable, Sendable {
    /// The media service's id for the file: the attachment's `fileId`.
    let fileID: String
    /// `contentId-<page id>`: the page the file is attached to.
    let collection: String?
    /// The file name, which Confluence's editor writes as the alt text.
    let filename: String?
    /// The image's own size in pixels, when the page says.
    let pixelWidth: Int?
    let pixelHeight: Int?
    /// How wide the page shows it, in pixels, when it says.
    let displayWidth: Int?

    var id: String { fileID }

    /// The page the file is attached to, by its collection.
    var pageID: String? {
        guard let collection, collection.hasPrefix("contentId-") else { return nil }
        return String(collection.dropFirst("contentId-".count))
    }

    /// Width over height, when known.
    var aspectRatio: CGFloat? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// The photo in an image block, or nil when the block shows something
    /// else (a link to an outside image, say).
    init?(block: ADFNode) {
        guard block.type == "mediaSingle",
              let media = block.children.first(where: { $0.type == "media" }),
              media.attr("type") == "file", let id = media.attr("id")
        else { return nil }
        fileID = id
        collection = media.attr("collection")
        filename = media.attr("alt")
        pixelWidth = media.intAttr("width")
        pixelHeight = media.intAttr("height")
        displayWidth = block.attr("widthType") == "pixel" ? block.intAttr("width") : nil
    }

    /// The longest side a new photo shows at on the page, in pixels: a
    /// glance under the priority, not the page's whole width. Opening it
    /// shows it full size.
    static let longestShownSide = 480

    /// The image block showing an attachment on page `pageID`: left-aligned
    /// under the item, `shownWidth` pixels wide or else no larger than
    /// `longestShownSide`.
    static func block(fileID: String, pageID: String, filename: String, pixelWidth: Int, pixelHeight: Int, shownWidth: Int? = nil) -> ADFNode {
        let width = max(pixelWidth, 1)
        let height = max(pixelHeight, 1)
        let shownWidth = shownWidth ?? (width >= height
            ? min(width, longestShownSide)
            : min(width, longestShownSide * width / height))
        let media = ADFNode(type: "media", attrs: [
            "type": .string("file"),
            "id": .string(fileID),
            "collection": .string("contentId-\(pageID)"),
            "alt": .string(filename),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
        ])
        return ADFNode(type: "mediaSingle", attrs: [
            "layout": .string("align-start"),
            "width": .number(Double(max(shownWidth, 1))),
            "widthType": .string("pixel"),
        ], content: [media])
    }
}

/// A photo on its way to a priority: shown from the picked image while it
/// uploads, before the page has it.
nonisolated struct PriorityPhotoUpload: Identifiable, Hashable, Sendable {
    let id: UUID
    let filename: String
    /// A small copy of the image to show meanwhile.
    let preview: Data?
    let pixelWidth: Int
    let pixelHeight: Int

    var aspectRatio: CGFloat {
        pixelWidth > 0 && pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 4 / 3
    }
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

/// One day's page under the Daily Priorities folder, named `yyyy-MM-dd`,
/// or the Product Questions page, which has no day of its own.
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
    /// Each item's photos, by item id; items without any aren't in it.
    var photos: [String: [PriorityPhoto]] { document.photosByItem }

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

/// A search through the priorities. Each word typed, or "phrase in quotes",
/// has to be somewhere in an item's text, ignoring case and accents.
nonisolated struct PrioritySearch: Hashable, Sendable {
    let terms: [String]

    init(_ text: String) {
        terms = text.matches(of: /"([^"]+)"|[^\s"]+/).compactMap { match in
            let term = String(match.output.1 ?? match.output.0).trimmingCharacters(in: .whitespaces)
            return term.isEmpty ? nil : term
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    func matches(_ text: String) -> Bool {
        !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: Self.options) != nil }
    }

    /// The days with items it finds, each with only those, in the order
    /// they're listed on the page; days newest first, or oldest first.
    func results(in days: [PriorityDay], order: PrioritySearchOrder) -> [PrioritySearchMatch] {
        let found = days.compactMap { day -> PrioritySearchMatch? in
            let items = day.items.filter { matches($0.plainText) }
            return items.isEmpty ? nil : PrioritySearchMatch(day: day, items: items)
        }
        return found.sorted { order == .oldestFirst ? $0.day.day < $1.day.day : $0.day.day > $1.day.day }
    }
}

/// The items a search found on one day.
nonisolated struct PrioritySearchMatch: Identifiable, Hashable, Sendable {
    let day: PriorityDay
    let items: [PriorityItem]

    var id: String { day.pageID }
}

/// Which way search results run by day.
nonisolated enum PrioritySearchOrder: String, CaseIterable, Sendable {
    case newestFirst, oldestFirst

    var title: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        }
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

    /// The page id in a link like `…/wiki/spaces/VPE1/pages/2420932609/Product+Questions`
    /// or `…/viewpage.action?pageId=2420932609`, or a bare id.
    static func pageID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: /\d+/) != nil { return text }
        guard let match = text.firstMatch(of: /\/pages\/(\d+)/) ?? text.firstMatch(of: /[?&]pageId=(\d+)/) else { return nil }
        return String(match.1)
    }

    /// The Product Questions page: one page with a checklist like a day's,
    /// shown under Daily Priorities. Found by title, like the folder.
    static let questionsPageTitle = "Product Questions"

    /// The site's one "Product Questions" page, or nil when there is none or
    /// more than one, in which case the user picks.
    static func findQuestionsPage(using client: JiraClient) async throws -> ConfluencePage? {
        let results = try await client.confluenceSearch(cql: "type = page and title = \"\(questionsPageTitle)\"")
        let ids = results.compactMap { result -> String? in
            guard let content = result.content, content.type == "page",
                  (content.title ?? result.title ?? "").caseInsensitiveCompare(questionsPageTitle) == .orderedSame
            else { return nil }
            return content.id
        }
        guard ids.count == 1 else { return nil }
        return try await client.confluencePage(id: ids[0])
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
    /// list, or to a new one at the end. When that list's last item has
    /// photos, the new list goes after them, so they stay that item's.
    func appendingTaskItem(_ items: [ADFNode]) -> ADFNode {
        var blocks = children
        if let index = blocks.lastIndex(where: { $0.type == "taskList" }) {
            let list = blocks[index]
            if let last = list.taskItems.last?.id, let end = photoBlocks.last(where: { $0.itemID == last })?.index {
                blocks.insert(ADFNode.taskList(items), at: end + 1)
            } else {
                blocks[index] = ADFNode(type: "taskList", attrs: list.attrs, content: list.children + items)
            }
        } else {
            blocks.append(ADFNode.taskList(items))
        }
        return ADFNode(type: type, attrs: attrs, content: blocks)
    }

    /// A copy with `item` right after the task item `id`, in the same list
    /// (or, when `id` has photos, after those, so they stay its); nil when
    /// there's no such item.
    func insertingTaskItem(_ item: ADFNode, after id: String) -> ADFNode? {
        if type == "doc", let end = photoBlocks.last(where: { $0.itemID == id })?.index {
            var blocks = children
            let next = end + 1
            if next < blocks.count, blocks[next].type == "taskList" {
                blocks[next] = ADFNode(type: "taskList", attrs: blocks[next].attrs, content: [item] + blocks[next].children)
            } else {
                blocks.insert(ADFNode.taskList([item]), at: next)
            }
            return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: blocks)
        }
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

    // MARK: Photos

    /// The document's top-level image blocks that sit under an item, each
    /// with its index among the top-level blocks and that item's id: the
    /// last item of the list before it, with nothing but blank lines and
    /// other photos in between.
    private var photoBlocks: [(index: Int, itemID: String, photo: PriorityPhoto)] {
        var owner: String?
        var found: [(index: Int, itemID: String, photo: PriorityPhoto)] = []
        for (index, block) in children.enumerated() {
            if block.type == "taskList" {
                owner = block.taskItems.last?.id
            } else if let photo = PriorityPhoto(block: block) {
                if let owner { found.append((index, owner, photo)) }
            } else if !block.isBlank {
                owner = nil
            }
        }
        return found
    }

    /// Each item's photos, in page order, by item id.
    var photosByItem: [String: [PriorityPhoto]] {
        Dictionary(grouping: photoBlocks, by: { $0.itemID }).mapValues { $0.map(\.photo) }
    }

    /// Where photos under item `id` go: its top-level list, and its place
    /// in that list. Nil when it isn't in a top-level list, or has indented
    /// items under it, which a photo can't come between.
    private func photoSpot(forItem id: String) -> (listIndex: Int, position: Int)? {
        for (index, block) in children.enumerated() where block.type == "taskList" {
            guard let position = block.children.firstIndex(where: { $0.type == "taskItem" && $0.attr("localId") == id }) else { continue }
            let next = position + 1
            if next < block.children.count, block.children[next].type != "taskItem" { return nil }
            return (index, position)
        }
        return nil
    }

    /// Whether item `id` can have photos added: it's on the page and not
    /// indented under another, nor has items indented under it.
    func canAddPhotos(toItem id: String) -> Bool {
        photoSpot(forItem: id) != nil
    }

    /// A copy with image blocks under item `id`, after any it has. When it
    /// isn't its list's last item, the list splits there, as Confluence's
    /// editor splits a checklist an image is pasted into. Nil when the item
    /// can't have photos (see `canAddPhotos`).
    func insertingPhotos(_ blocks: [ADFNode], underItem id: String) -> ADFNode? {
        guard let spot = photoSpot(forItem: id) else { return nil }
        var top = children
        let list = top[spot.listIndex]
        if spot.position == list.children.count - 1 {
            let end = photoBlocks.last(where: { $0.itemID == id })?.index ?? spot.listIndex
            top.insert(contentsOf: blocks, at: end + 1)
        } else {
            let before = ADFNode(type: "taskList", attrs: list.attrs, content: Array(list.children[...spot.position]))
            let after = ADFNode.taskList(Array(list.children[(spot.position + 1)...]))
            top.replaceSubrange(spot.listIndex...spot.listIndex, with: [before] + blocks + [after])
        }
        return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: top)
    }

    /// A copy without item `id`'s photos, or the blank lines among them.
    /// Where that leaves its list touching the next one, they're joined
    /// back into one, as they were before the photos split them.
    func removingPhotos(ofItem id: String) -> ADFNode {
        let owned = photoBlocks.filter { $0.itemID == id }.map(\.index)
        guard let first = owned.first, let last = owned.last,
              let listIndex = children[..<first].lastIndex(where: { $0.type == "taskList" }) else { return self }
        var top = children
        top.removeSubrange((listIndex + 1)...last)
        let next = listIndex + 1
        if next < top.count, top[next].type == "taskList" {
            top[listIndex] = ADFNode(type: "taskList", attrs: top[listIndex].attrs, content: top[listIndex].children + top[next].children)
            top.remove(at: next)
        }
        return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: top)
    }

    /// A copy without one of item `id`'s photos; the last one goes as
    /// `removingPhotos` takes them all.
    func removingPhoto(_ fileID: String, ofItem id: String) -> ADFNode {
        let owned = photoBlocks.filter { $0.itemID == id }
        guard let target = owned.first(where: { $0.photo.fileID == fileID }) else { return self }
        if owned.count == 1 { return removingPhotos(ofItem: id) }
        var top = children
        top.remove(at: target.index)
        return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: top)
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

    /// Whether the document shows nothing: no text, checkboxes, cards or
    /// anything else, only empty paragraphs and lists.
    var isBlank: Bool {
        switch type {
        case "doc", "paragraph", "taskList", "bulletList", "orderedList": children.allSatisfy(\.isBlank)
        case "text": (text ?? "").allSatisfy(\.isWhitespace)
        case "hardBreak": true
        default: false
        }
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
    /// app, web links become links, `[text](address)` becomes text linked to
    /// the address, line breaks become hard breaks, the rest stays text.
    static func inlineContent(from text: String, siteURL: URL) -> [ADFNode] {
        var nodes: [ADFNode] = []
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if index > 0 { nodes.append(ADFNode(type: "hardBreak")) }
            nodes += lineContent(from: line, siteURL: siteURL)
        }
        return nodes
    }

    /// A link written `[text](address)`, as in Markdown and as pasting an
    /// address over selected text writes it. The address can hold one level
    /// of parentheses, as Wikipedia's do.
    static var typedLink: Regex<(Substring, Substring, Substring)> {
        /\[([^\[\]\n]+)\]\((https?:\/\/(?:[^\s()]|\([^\s()]*\))+)\)/
    }

    private static func lineContent(from text: Substring, siteURL: URL) -> [ADFNode] {
        var nodes: [ADFNode] = []
        var rest = text
        while let match = rest.firstMatch(of: typedLink) {
            nodes += wordContent(from: rest[..<match.range.lowerBound], siteURL: siteURL)
            nodes.append(ADFNode(type: "text", text: String(match.1), marks: [ADFMark(type: "link", attrs: ["href": .string(String(match.2))])]))
            rest = rest[match.range.upperBound...]
        }
        return nodes + wordContent(from: rest, siteURL: siteURL)
    }

    private static func wordContent(from text: Substring, siteURL: URL) -> [ADFNode] {
        var nodes: [ADFNode] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { nodes.append(ADFNode(type: "text", text: plain)); plain = "" }
        }
        for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let token = String(word)
            // Trailing punctuation stays outside the link or card.
            let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
            let trailing = String(token.dropFirst(core.count))
            if index > 0 { plain += " " }
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

    /// When an edit from `old` to `new` pasted a web address over selected
    /// text, where the address landed in `new` and the `[text](address)`
    /// to put there instead, making that text a link to it. Spaces at the
    /// ends of the selection stay outside the link. Nil for any other edit,
    /// such as a paste with nothing selected (which saving links anyway).
    /// `pasted` gives what was pasted; it's asked only for an edit that
    /// could be a paste, not a keystroke.
    static func linkingPaste(from old: String, to new: String, pasted: () -> String?) -> (range: Range<String.Index>, link: String)? {
        let oldChars = Array(old)
        let newChars = Array(new)
        let shared = sharedEnds(oldChars, newChars)
        let changeEnd = newChars.count - min(shared.suffix, min(oldChars.count, newChars.count) - shared.prefix)
        guard changeEnd - shared.prefix > 1, let raw = pasted() else { return nil }
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let insert = Array(raw)
        guard !address.isEmpty, insert.count <= newChars.count else { return nil }
        // Where the paste went: text before it that `old` starts with, after
        // it that `old` ends with, and the selection it replaced between.
        for start in 0...(newChars.count - insert.count) where start <= shared.prefix {
            let end = start + insert.count
            let tail = newChars.count - end
            guard tail <= shared.suffix, oldChars.count - tail > start,
                  newChars[start..<end].elementsEqual(insert) else { continue }
            let selectedRange = old.index(old.startIndex, offsetBy: start)..<old.index(old.endIndex, offsetBy: -tail)
            let selected = old[selectedRange]
            let text = selected.trimmingCharacters(in: .whitespaces)
            let link = "[\(text)](\(address))"
            // Not over an address (that's replacing one link with another),
            // nor over part of a link already written out.
            guard !text.isEmpty, !text.contains("://"), link.wholeMatch(of: typedLink) != nil,
                  !old.matches(of: typedLink).contains(where: { $0.range.overlaps(selectedRange) }) else { return nil }
            let leading = selected.prefix(while: \.isWhitespace)
            let trailing = selected.reversed().prefix(while: \.isWhitespace)
            let range = new.index(new.startIndex, offsetBy: start)..<new.index(new.startIndex, offsetBy: end)
            return (range, String(leading) + link + String(trailing.reversed()))
        }
        return nil
    }

    /// The web address an edit from `old` to `new` put in all at once, as a
    /// paste does, worked out from the text alone, since on iOS reading the
    /// pasteboard asks the user first. It's the word holding the change,
    /// from where `http://` or `https://` starts, less punctuation after it
    /// as when typed.
    static func insertedWebAddress(from old: String, to new: String) -> String? {
        let oldChars = Array(old)
        let newChars = Array(new)
        let shared = sharedEnds(oldChars, newChars)
        let changeEnd = newChars.count - min(shared.suffix, min(oldChars.count, newChars.count) - shared.prefix)
        guard changeEnd > shared.prefix else { return nil }
        var wordStart = shared.prefix
        while wordStart > 0, !newChars[wordStart - 1].isWhitespace { wordStart -= 1 }
        guard let start = (wordStart...shared.prefix).last(where: {
            newChars[$0...].starts(with: "https://") || newChars[$0...].starts(with: "http://")
        }) else { return nil }
        var end = changeEnd
        while end < newChars.count, !newChars[end].isWhitespace { end += 1 }
        while end > changeEnd, ".,;:!?)".contains(newChars[end - 1]) { end -= 1 }
        let word = newChars[start..<end]
        return word.contains(where: \.isWhitespace) ? nil : String(word)
    }

    /// How many characters two texts share at the start and at the end,
    /// each counted on its own, so the two can overlap.
    private static func sharedEnds(_ a: [Character], _ b: [Character]) -> (prefix: Int, suffix: Int) {
        (zip(a, b).prefix { $0 == $1 }.count, zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count)
    }
}

nonisolated extension ADFMark {
    /// The highlight an inline comment hangs on.
    var isInlineComment: Bool { type == "annotation" && attr("annotationType") == "inlineComment" }
}

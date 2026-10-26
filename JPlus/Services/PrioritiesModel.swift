import Foundation
import Observation

/// Indexes the day pages under the Daily Priorities folder, loads the ones
/// on screen, and writes edits back. An edit shows at once, and the save
/// catches up. Every write re-reads the page first and saves over its
/// current version, retrying if someone else saved in between, so two people
/// ticking boxes at once don't lose each other's changes.
@Observable
final class PrioritiesModel {
    /// The root folder, once loaded.
    private(set) var folder: ConfluenceFolder?
    /// Every day page under the folder, newest first. Titles only; bodies
    /// load when a day is shown.
    private(set) var index: [PriorityDayRef] = []
    /// Loaded day pages by page id.
    private(set) var pages: [String: PriorityDay] = [:]
    /// Each loaded page's open comment threads, by page id; none until its
    /// comments have loaded.
    private(set) var commentThreads: [String: [PriorityCommentThread]] = [:]
    /// Comment authors by account id.
    private(set) var people: [String: JiraUser] = [:]
    /// Days in the main pane, top first: the selected day, then each earlier
    /// day loaded below it — the last few at first, more with Load Previous Day.
    private(set) var shownIDs: [String] = []
    private(set) var loadingPageIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Ids of items with a save in flight.
    private(set) var busyItemIDs: Set<String> = []
    /// Changes waiting to save, oldest first, each by the id of its write
    /// (or of the move it's part of). The screen is locked while any are.
    private var saveQueue: [(id: UUID, save: PrioritySave)] = []
    /// True while a new day's page is being created.
    private(set) var isCreatingDay = false
    /// Ids of day pages being archived.
    private(set) var archivingPageIDs: Set<String> = []

    private var client: JiraClient?
    private var folderID = ""
    /// Set when the model shows one page on its own (Product Questions)
    /// rather than the days under a folder.
    private var singlePageID: String?
    /// Month folder titles → ids, from the last load.
    private var monthFolderIDs: [String: String] = [:]
    /// Writes run one after another, so edits to the same page don't race.
    /// Each ends with whether it saved.
    private var lastWrite: Task<Bool, Never>?
    /// Edits not yet saved, oldest first. A save that finishes shows its page
    /// with these still applied, so an edit made since doesn't blink away.
    @ObservationIgnored private var pendingEdits: [(id: UUID, pageID: String, transform: (ADFNode) -> ADFNode)] = []
    private var generation = 0
    /// How many days the main pane opens with.
    private let initialDayCount = 5
    /// How long archiving a day follows Confluence's background job.
    private static let archiveWait: Duration = .seconds(30)

    var siteURL: URL { client?.credentials.siteURL ?? URL(string: "https://atlassian.net")! }

    var todayTitle: String { PriorityNaming.dayTitle(for: Date()) }
    var todayRef: PriorityDayRef? { ref(titled: todayTitle) }
    var selectedID: String? { shownIDs.first }
    var shownDays: [PriorityDay] { shownIDs.compactMap { pages[$0] } }

    /// The change saving now, while one is.
    var saving: PrioritySave? { saveQueue.first?.save }
    /// How many more changes are waiting behind it.
    var savesWaiting: Int { max(0, saveQueue.count - 1) }

    func ref(titled title: String) -> PriorityDayRef? { index.first { $0.title == title } }
    func ref(for date: Date) -> PriorityDayRef? { ref(titled: PriorityNaming.dayTitle(for: date)) }

    /// The next earlier day after the last one shown.
    var previousRef: PriorityDayRef? {
        guard let last = shownIDs.last, let position = index.firstIndex(where: { $0.pageID == last }) else { return nil }
        let next = index.index(after: position)
        return next < index.endIndex ? index[next] : nil
    }

    /// The most recent day before `date`, which a new day can copy from.
    func dayBefore(_ date: Date) -> PriorityDayRef? {
        let title = PriorityNaming.dayTitle(for: date)
        return index.first { $0.title < title }
    }

    /// The open comment threads on an item: those whose highlight is in its text.
    func threads(on item: PriorityItem, in day: PriorityDay) -> [PriorityCommentThread] {
        let markers = item.commentMarkerIDs
        guard !markers.isEmpty else { return [] }
        return (commentThreads[day.pageID] ?? []).filter { $0.root.markerRef.map(markers.contains) ?? false }
    }

    /// Whether an item has open comments, so its text stays as it is: the
    /// comments hang on that text, and rewriting it would cut them loose.
    /// Until the page's comments load, any highlight counts.
    func hasComments(_ item: PriorityItem, in day: PriorityDay) -> Bool {
        if item.commentMarkerIDs.isEmpty { return false }
        guard commentThreads[day.pageID] != nil else { return true }
        return !threads(on: item, in: day).isEmpty
    }

    // MARK: - Loading

    func load(client: JiraClient, folderID: String) async {
        self.client = client
        self.folderID = folderID
        singlePageID = nil
        generation += 1
        let myGeneration = generation
        isLoading = true
        errorMessage = nil
        var cancelled = false
        // A cancelled load doesn't count as loaded, so the spinner stays until it runs again.
        defer { if myGeneration == generation { isLoading = false; if !cancelled { hasLoaded = true } } }
        do {
            async let folder = client.confluenceFolder(id: folderID)
            let children = try await client.confluenceFolderChildren(id: folderID)
            let months = children.filter { $0.type == "folder" && PriorityNaming.isMonthTitle($0.title) }
            let listed = try await withThrowingTaskGroup(of: (String, [ConfluenceChild]).self) { group in
                for month in months {
                    group.addTask { (month.id, try await client.confluenceFolderChildren(id: month.id)) }
                }
                var listed: [(String, [ConfluenceChild])] = []
                for try await entry in group { listed.append(entry) }
                return listed
            }
            let root = try await folder
            guard myGeneration == generation else { return }
            self.folder = root
            monthFolderIDs = Dictionary(months.map { ($0.title, $0.id) }, uniquingKeysWith: { first, _ in first })
            index = listed
                .flatMap { monthID, children in
                    children.compactMap { child -> PriorityDayRef? in
                        guard child.type == "page", PriorityNaming.isDayTitle(child.title),
                              let day = PriorityNaming.day(fromTitle: child.title) else { return nil }
                        return PriorityDayRef(pageID: child.id, title: child.title, day: day, monthFolderID: monthID)
                    }
                }
                .sorted { $0.title > $1.title }

            // Keep what was on screen if it still exists; otherwise open the
            // last few days.
            let known = Set(index.map(\.pageID))
            shownIDs = shownIDs.filter(known.contains)
            if shownIDs.isEmpty { shownIDs = openingDayIDs }
            pages = pages.filter { known.contains($0.key) }
            commentThreads = commentThreads.filter { known.contains($0.key) }
            await withTaskGroup(of: Void.self) { group in
                for id in shownIDs { group.addTask { await self.loadDay(id) } }
            }
        } catch where error.isCancellation {
            cancelled = true
        } catch {
            guard myGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Shows one checklist page on its own, edited as a day is. It has no
    /// day, so it's never today's and has none before it.
    func load(client: JiraClient, pageID: String) async {
        self.client = client
        singlePageID = pageID
        generation += 1
        let myGeneration = generation
        isLoading = true
        errorMessage = nil
        var cancelled = false
        defer { if myGeneration == generation { isLoading = false; if !cancelled { hasLoaded = true } } }
        do {
            let page = try await client.confluencePage(id: pageID)
            guard myGeneration == generation else { return }
            let ref = PriorityDayRef(pageID: page.id, title: page.title, day: .distantPast, monthFolderID: "")
            index = [ref]
            shownIDs = [page.id]
            pages = [page.id: PriorityDay(page: page, day: ref.day, siteURL: client.credentials.siteURL)]
            commentThreads = commentThreads.filter { $0.key == page.id }
            await loadComments(page.id)
        } catch where error.isCancellation {
            cancelled = true
        } catch {
            guard myGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// The days the main pane opens with: the last few, starting from today
    /// or the latest day.
    private var openingDayIDs: [String] {
        guard let first = todayRef ?? index.first,
              let start = index.firstIndex(where: { $0.pageID == first.pageID }) else { return [] }
        return index[start...].prefix(initialDayCount).map(\.pageID)
    }

    func reload() async {
        guard let client else { return }
        if let singlePageID {
            await load(client: client, pageID: singlePageID)
        } else {
            await load(client: client, folderID: folderID)
        }
    }

    /// Shows one day on its own, as picked from the day list.
    func select(_ pageID: String) async {
        guard selectedID != pageID || shownIDs.count > 1 else { return }
        shownIDs = [pageID]
        if pages[pageID] == nil { await loadDay(pageID) }
    }

    /// Adds the next earlier day below the ones shown.
    func loadPrevious() async {
        guard let ref = previousRef else { return }
        shownIDs.append(ref.pageID)
        if pages[ref.pageID] == nil { await loadDay(ref.pageID) }
    }

    /// Loads a day's page and its comments side by side.
    private func loadDay(_ pageID: String) async {
        async let comments: Void = loadComments(pageID)
        await loadPage(pageID)
        await comments
    }

    private func loadPage(_ pageID: String) async {
        guard let client, let ref = index.first(where: { $0.pageID == pageID }) else { return }
        loadingPageIDs.insert(pageID)
        defer { loadingPageIDs.remove(pageID) }
        do {
            let page = try await client.confluencePage(id: pageID)
            pages[pageID] = PriorityDay(page: page, day: ref.day, siteURL: client.credentials.siteURL)
        } catch where error.isCancellation {
            return
        } catch {
            errorMessage = "Couldn't load \(ref.title): \(error.localizedDescription)"
        }
    }

    /// Loads a page's open inline comments, each with its replies, and then
    /// who wrote them.
    private func loadComments(_ pageID: String) async {
        guard let client, let ref = index.first(where: { $0.pageID == pageID }) else { return }
        do {
            let roots = try await client.confluenceInlineComments(pageID: pageID)
            let replies = try await withThrowingTaskGroup(of: (String, [ConfluenceComment]).self) { group in
                for root in roots {
                    group.addTask { (root.id, try await client.confluenceCommentReplies(commentID: root.id)) }
                }
                var replies: [String: [ConfluenceComment]] = [:]
                for try await (id, found) in group { replies[id] = found }
                return replies
            }
            let threads = roots.map { PriorityCommentThread(root: $0, replies: replies[$0.id] ?? []) }
            // Names first, so the comments don't show up nameless.
            await loadPeople(threads.flatMap { [$0.root] + $0.replies }.compactMap(\.authorID))
            commentThreads[pageID] = threads
        } catch where error.isCancellation {
            return
        } catch {
            errorMessage = "Couldn't load the comments on \(ref.title): \(error.localizedDescription)"
        }
    }

    /// Looks up the people not yet known. Without them, comments show no name.
    private func loadPeople(_ accountIDs: [String]) async {
        let missing = Set(accountIDs).subtracting(people.keys)
        guard let client, !missing.isEmpty,
              let found = try? await client.users(accountIDs: missing.sorted()) else { return }
        for person in found { people[person.accountId] = person }
    }

    /// Replies in a comment thread, a paragraph per typed line, then reads
    /// the thread's replies back so this one shows along with any posted
    /// since. Throws when the reply wasn't posted, so the box keeps its text.
    func reply(_ text: String, to thread: PriorityCommentThread, in day: PriorityDay) async throws {
        guard let client, let document = commentDocument(text) else { return }
        let posted = try await client.replyToConfluenceComment(thread.root.id, document: document)
        // It's posted either way; if reading back fails, show it as sent.
        let replies = (try? await client.confluenceCommentReplies(commentID: thread.root.id)) ?? thread.replies + [posted]
        await loadPeople(replies.compactMap(\.authorID))
        commentThreads[day.pageID] = commentThreads[day.pageID]?.map {
            $0.id == thread.id ? PriorityCommentThread(root: $0.root, replies: replies) : $0
        }
    }

    /// Starts a comment thread on an item, as selecting its text and
    /// commenting does in Confluence, which highlights that text on the page.
    /// Then reads the page and its comments back, so both show. Throws when
    /// the comment wasn't posted, so the box keeps its text.
    func comment(_ text: String, on item: PriorityItem, in day: PriorityDay) async throws {
        guard let client, let document = commentDocument(text) else { return }
        // After the edits waiting to save, so the page has the text as shown.
        _ = await lastWrite?.value
        let page = try await client.confluencePage(id: day.pageID)
        guard let anchor = page.document.commentAnchor(forItem: item.id) else {
            throw CommentError.noText
        }
        try await client.createConfluenceInlineComment(pageID: day.pageID, document: document, selection: anchor.text,
                                                       matchIndex: anchor.index, matchCount: anchor.count)
        // It's posted either way; the next load shows it if these fail.
        if let page = try? await client.confluencePage(id: day.pageID) {
            var updated = PriorityDay(page: page, day: day.day, siteURL: client.credentials.siteURL)
            updated.document = pendingEdits.filter { $0.pageID == day.pageID }.reduce(updated.document) { $1.transform($0) }
            pages[day.pageID] = updated
        }
        await loadComments(day.pageID)
    }

    enum CommentError: LocalizedError {
        case noText

        var errorDescription: String? {
            switch self {
            case .noText: "This priority has no text to comment on, or it has gone."
            }
        }
    }

    /// Typed text as a comment, a paragraph per line; nil when it's blank.
    private func commentDocument(_ text: String) -> ADFNode? {
        let paragraphs = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ADFNode(type: "paragraph", content: ADFNode.inlineContent(from: $0, siteURL: siteURL)) }
        return paragraphs.isEmpty ? nil : ADFNode(type: "doc", content: paragraphs)
    }

    // MARK: - New day

    /// Creates the page for `date`, inside its month's folder (made if
    /// needed). Refuses a date that already has a page. With `copyingFrom`,
    /// that day's unfinished items start the new page.
    @discardableResult
    func createDay(_ date: Date, copyingFrom source: PriorityDayRef? = nil) async -> Bool {
        guard let client, let spaceID = folder?.spaceId else { return false }
        let title = PriorityNaming.dayTitle(for: date)
        if let existing = ref(titled: title) {
            errorMessage = "\(title) already exists."
            await select(existing.pageID)
            return false
        }
        isCreatingDay = true
        defer { isCreatingDay = false }
        errorMessage = nil
        do {
            var items: [ADFNode] = []
            if let source {
                let page = try await client.confluencePage(id: source.pageID)
                // The comments stay on the source page, so their highlights don't come along.
                items = page.document.taskItems.filter { !$0.isDone }.map { ADFNode.taskItem($0.contentWithoutComments) }
            }

            let monthTitle = PriorityNaming.monthTitle(for: date)
            let monthID: String
            if let known = monthFolderIDs[monthTitle] {
                monthID = known
            } else if let found = try await client.confluenceFolderChildren(id: folderID)
                        .first(where: { $0.type == "folder" && $0.title == monthTitle }) {
                // Someone else started the month since the last load.
                monthID = found.id
            } else {
                monthID = try await client.createConfluenceFolder(title: monthTitle, spaceID: spaceID, parentID: folderID).id
            }
            monthFolderIDs[monthTitle] = monthID

            // Someone else may have made the day since the last load.
            if let child = try await client.confluenceFolderChildren(id: monthID)
                .first(where: { $0.type == "page" && $0.title == title }) {
                insert(PriorityDayRef(pageID: child.id, title: title, day: date, monthFolderID: monthID))
                errorMessage = "\(title) already exists."
                await select(child.id)
                return false
            }

            let document = ADFNode(type: "doc", content: items.isEmpty ? [] : [ADFNode.taskList(items)])
            let created = try await client.createConfluencePage(title: title, spaceID: spaceID, parentID: monthID, document: document)
            // Read it back so the page has its links and normalized body.
            let page = (try? await client.confluencePage(id: created.id)) ?? created
            insert(PriorityDayRef(pageID: page.id, title: title, day: date, monthFolderID: monthID))
            pages[page.id] = PriorityDay(page: page, day: date, siteURL: client.credentials.siteURL)
            commentThreads[page.id] = []
            shownIDs = [page.id]
            return true
        } catch {
            errorMessage = "Couldn't create \(title): \(error.localizedDescription)"
            return false
        }
    }

    private func insert(_ ref: PriorityDayRef) {
        index.removeAll { $0.title == ref.title }
        index.append(ref)
        index.sort { $0.title > $1.title }
    }

    // MARK: - Archiving a day

    /// A day's page as it is now in Confluence, so archiving it can warn
    /// about what's on it, including anything added since it loaded. Nil,
    /// with the error shown, when it couldn't be read.
    func currentPage(of ref: PriorityDayRef) async -> PriorityDay? {
        guard let client else { return nil }
        do {
            let page = try await client.confluencePage(id: ref.pageID)
            return PriorityDay(page: page, day: ref.day, siteURL: client.credentials.siteURL)
        } catch {
            errorMessage = "Couldn't read \(ref.title): \(error.localizedDescription)"
            return nil
        }
    }

    /// Archives a day's page, which Confluence moves out of its month folder
    /// into the space's archive, where it can be restored, and takes it off
    /// the screen. Its month folder stays, even when left empty. Confluence
    /// archives in the background, sometimes after a wait in its queue, so
    /// this follows along for a while; past that, the day goes anyway, with
    /// a note that it may show again until Confluence is done.
    func archiveDay(_ ref: PriorityDayRef) async {
        guard let client else { return }
        archivingPageIDs.insert(ref.pageID)
        defer { archivingPageIDs.remove(ref.pageID) }
        // After any edit still saving, which would otherwise land on an archived page.
        _ = await lastWrite?.value
        let taskID: String
        do {
            taskID = try await client.archiveConfluencePage(id: ref.pageID)
        } catch JiraError.forbidden, JiraError.notFound {
            // Confluence answers 404 too, to someone it won't let archive the page.
            errorMessage = "Confluence didn't let you archive \(ref.title). Your account may not be allowed to archive pages in this space."
            return
        } catch {
            errorMessage = "Couldn't archive \(ref.title): \(error.localizedDescription)"
            return
        }
        // It was accepted, so a status that won't load counts as still going.
        var task = try? await client.confluenceLongTask(id: taskID)
        let deadline = ContinuousClock.now + Self.archiveWait
        while task?.finished != true, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            task = try? await client.confluenceLongTask(id: taskID)
        }
        if let task, task.finished, !task.successful {
            let reason = task.problems.isEmpty ? "." : ": " + task.problems.joined(separator: " ")
            errorMessage = "Confluence couldn't archive \(ref.title)\(reason)"
            return
        }
        errorMessage = task?.finished == true ? nil
            : "Confluence is still archiving \(ref.title), so it may show again on Refresh until that's done."
        index.removeAll { $0.pageID == ref.pageID }
        pages[ref.pageID] = nil
        commentThreads[ref.pageID] = nil
        shownIDs.removeAll { $0 == ref.pageID }
        if shownIDs.isEmpty {
            shownIDs = openingDayIDs
            await withTaskGroup(of: Void.self) { group in
                for id in shownIDs where pages[id] == nil { group.addTask { await self.loadDay(id) } }
            }
        }
    }

    // MARK: - Edits

    func setDone(_ done: Bool, item: PriorityItem, in day: PriorityDay) {
        write(page: day.pageID, itemID: item.id, message: done ? "Done: \(item.plainText.prefix(60))" : "Reopened: \(item.plainText.prefix(60))",
              showing: PrioritySave(change: .saving, text: item.plainText, isDone: done)) { document in
            document.replacingTaskItems { current, node in
                current.id == item.id ? node.settingTaskState(done: done) : node
            }
        }
    }

    func setText(_ text: String, item: PriorityItem, in day: PriorityDay) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(item, from: day) }
        let content = ADFNode.inlineContent(from: trimmed, siteURL: siteURL)
        write(page: day.pageID, itemID: item.id, message: "Edited: \(trimmed.prefix(60))",
              showing: PrioritySave(change: .saving, text: trimmed, isDone: item.isDone)) { document in
            document.replacingTaskItems { current, node in
                current.id == item.id ? ADFNode(type: node.type, attrs: node.attrs, content: content) : node
            }
        }
    }

    func remove(_ item: PriorityItem, from day: PriorityDay) {
        remove(item, from: day, showing: PrioritySave(change: .deleting, text: item.plainText, isDone: item.isDone))
    }

    @discardableResult
    private func remove(_ item: PriorityItem, from day: PriorityDay, showing save: PrioritySave?) -> Task<Bool, Never>? {
        write(page: day.pageID, itemID: item.id, message: "Removed: \(item.plainText.prefix(60))", showing: save) { document in
            document.replacingTaskItems { current, node in current.id == item.id ? nil : node }
        }
    }

    /// Adds a priority right after `itemID`, or at the end of the day's list
    /// (also when that item has gone). Returns the new item's id, or nil for
    /// blank text, which isn't added.
    @discardableResult
    func add(_ text: String, to day: PriorityDay, after itemID: String? = nil) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID().uuidString.lowercased()
        let item = ADFNode.taskItem(ADFNode.inlineContent(from: trimmed, siteURL: siteURL), id: id)
        write(page: day.pageID, itemID: id, message: "Added: \(trimmed.prefix(60))",
              showing: PrioritySave(change: .adding, text: trimmed, isDone: false)) { document in
            itemID.flatMap { document.insertingTaskItem(item, after: $0) } ?? document.appendingTaskItem([item])
        }
        return id
    }

    /// Moves an item from an earlier day onto today's page, when today has
    /// one. Not one with comments, which can't move with it.
    func moveToToday(_ item: PriorityItem, from day: PriorityDay) async {
        guard let today = todayRef, today.pageID != day.pageID, !hasComments(item, in: day) else { return }
        // One change on screen across both pages' saves, so the screen stays
        // locked in between.
        let moveID = UUID()
        saveQueue.append((moveID, PrioritySave(change: .moving, text: item.plainText, isDone: item.isDone)))
        defer { saveQueue.removeAll { $0.id == moveID } }
        let moved = ADFNode.taskItem(item.contentWithoutComments, done: item.isDone, id: item.id)
        let added = write(page: today.pageID, itemID: item.id, message: "Moved from \(day.title): \(item.plainText.prefix(50))", showing: nil) { $0.appendingTaskItem([moved]) }
        // Only off its own day once it's on today's, so a failed save can't lose it.
        guard await added?.value == true else { return }
        _ = await remove(item, from: day, showing: nil)?.value
    }

    /// Shows a change to a page at once and queues it: fetch, transform, save;
    /// again on a version conflict. The loaded copy is then replaced by what
    /// was saved, with any later edits still waiting on top. `save` is how
    /// the screen shows it until then; nil when the caller shows it. The
    /// write ends with whether it saved.
    @discardableResult
    private func write(page pageID: String, itemID: String?, message: String, showing save: PrioritySave?, transform: @escaping (ADFNode) -> ADFNode) -> Task<Bool, Never>? {
        guard let client else { return nil }
        if let itemID { busyItemIDs.insert(itemID) }
        let editID = UUID()
        pendingEdits.append((editID, pageID, transform))
        if let save { saveQueue.append((editID, save)) }
        if let document = pages[pageID]?.document { pages[pageID]?.document = transform(document) }
        let previous = lastWrite
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            defer {
                if let itemID { busyItemIDs.remove(itemID) }
                pendingEdits.removeAll { $0.id == editID }
                saveQueue.removeAll { $0.id == editID }
            }
            var attempts = 0
            while true {
                attempts += 1
                do {
                    let current = try await client.confluencePage(id: pageID)
                    let document = transform(current.document)
                    let saved = try await client.updateConfluencePage(id: pageID, title: current.title, version: current.version.number + 1, document: document, message: message)
                    pages[pageID]?.version = saved.version.number
                    pages[pageID]?.document = pendingEdits
                        .filter { $0.pageID == pageID && $0.id != editID }
                        .reduce(document) { $1.transform($0) }
                    errorMessage = nil
                    return true
                } catch let error as JiraError where error.isConflict && attempts < 3 {
                    continue
                } catch {
                    // After the reload, which clears the message as it starts.
                    await reload()
                    errorMessage = "Couldn't save to Confluence: \(error.localizedDescription)"
                    return false
                }
            }
        }
        lastWrite = task
        return task
    }
}

private extension ADFNode {
    func settingTaskState(done: Bool) -> ADFNode {
        var attrs = self.attrs ?? [:]
        attrs["state"] = .string(done ? "DONE" : "TODO")
        return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: content)
    }
}

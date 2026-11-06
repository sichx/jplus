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
    /// Every day's page as search last read them, by page id.
    private(set) var searchDays: [String: PriorityDay] = [:]
    /// True while search reads every day's page.
    private(set) var isLoadingSearch = false
    private(set) var searchError: String?
    /// When search last read every day, so it doesn't read them again for
    /// each search.
    private var searchLoadedAt: ContinuousClock.Instant?
    /// How long what search read is used before it's read again.
    private static let searchFreshness: Duration = .seconds(60)
    /// Photos uploading under each item, by item id, shown from the picked
    /// images until the page has them.
    private(set) var photoUploads: [String: [PriorityPhotoUpload]] = [:]
    /// Each page's attachments as last listed, by page id, to find the file
    /// a photo on it shows.
    @ObservationIgnored private var attachmentLists: [String: [ConfluenceAttachment]] = [:]
    @ObservationIgnored private var attachmentLoads: [String: Task<[ConfluenceAttachment], Error>] = [:]

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
    private let initialDayCount = 3
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
        if folderID != self.folderID || client.credentials.siteURL != self.client?.credentials.siteURL {
            searchDays = [:]
            searchLoadedAt = nil
        }
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
            // Search reads every day again too, once it has read them before.
            if searchLoadedAt != nil {
                searchLoadedAt = nil
                await loadSearchDays()
            }
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

    // MARK: - Search

    /// Every day search looks through, newest first. A day on screen can
    /// have edits that haven't saved yet, so that copy counts, unless search
    /// has read a newer version of it since.
    var searchableDays: [PriorityDay] {
        index.compactMap { ref in
            let shown = pages[ref.pageID]
            let read = searchDays[ref.pageID]
            guard let shown else { return read }
            guard let read, read.version > shown.version else { return shown }
            return read
        }
    }

    /// Reads every day's page for search, in a request or two, unless it did
    /// in the last minute. Until it's done, search looks through the days
    /// already loaded.
    func loadSearchDays() async {
        guard let client, singlePageID == nil, !index.isEmpty, !isLoadingSearch else { return }
        if let searchLoadedAt, ContinuousClock.now - searchLoadedAt < Self.searchFreshness { return }
        isLoadingSearch = true
        defer { isLoadingSearch = false }
        do {
            let found = try await client.confluencePages(ids: index.map(\.pageID))
            // The days as they are now, in case one went or came while reading.
            let refs = Dictionary(index.map { ($0.pageID, $0) }, uniquingKeysWith: { first, _ in first })
            var days: [String: PriorityDay] = [:]
            for page in found {
                guard let ref = refs[page.id] else { continue }
                days[page.id] = PriorityDay(page: page, day: ref.day, siteURL: client.credentials.siteURL)
            }
            searchDays = days
            searchLoadedAt = .now
            searchError = nil
        } catch where error.isCancellation {
            return
        } catch {
            searchError = "Couldn't read every day to search them: \(error.localizedDescription)"
        }
    }

    /// Shows a day search found on its own, at once: from the copy search
    /// read when that's newer than the one loaded (and nothing on it is
    /// waiting to save). Its comments load after.
    func showFound(_ pageID: String) {
        shownIDs = [pageID]
        if let read = searchDays[pageID], read.version > pages[pageID]?.version ?? 0,
           !pendingEdits.contains(where: { $0.pageID == pageID }) {
            pages[pageID] = read
        }
        if pages[pageID] == nil {
            Task { await loadDay(pageID) }
        } else if commentThreads[pageID] == nil {
            Task { await loadComments(pageID) }
        }
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
            /// Copied items' photos, by the copy's id, to attach to the new page once it's made.
            var photoCopies: [(itemID: String, photos: [PriorityPhoto])] = []
            if let source {
                let page = try await client.confluencePage(id: source.pageID)
                let photos = page.document.photosByItem
                // The comments stay on the source page, so their highlights don't come along.
                for item in page.document.taskItems where !item.isDone {
                    let copy = ADFNode.taskItem(item.contentWithoutComments)
                    items.append(copy)
                    if let photos = photos[item.id], let id = copy.attr("localId") { photoCopies.append((id, photos)) }
                }
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
            // The photos' files are attached to the new page too, and shown
            // under their items there. The day is made either way.
            var photoNote: String?
            if let source, !photoCopies.isEmpty {
                do {
                    var withPhotos = document
                    for copy in photoCopies {
                        var blocks: [ADFNode] = []
                        for photo in copy.photos { blocks.append(try await self.copy(photo, fromPage: source.pageID, toPage: created.id)) }
                        withPhotos = withPhotos.insertingPhotos(blocks, underItem: copy.itemID) ?? withPhotos
                    }
                    _ = try await client.updateConfluencePage(id: created.id, title: title, version: created.version.number + 1,
                                                              document: withPhotos, message: "Photos from \(source.title)")
                } catch {
                    photoNote = "\(title) was made, but the photos didn't all copy from \(source.title): \(error.localizedDescription)"
                }
            }
            // Read it back so the page has its links and normalized body.
            let page = (try? await client.confluencePage(id: created.id)) ?? created
            insert(PriorityDayRef(pageID: page.id, title: title, day: date, monthFolderID: monthID))
            pages[page.id] = PriorityDay(page: page, day: date, siteURL: client.credentials.siteURL)
            commentThreads[page.id] = []
            shownIDs = [page.id]
            if let photoNote { errorMessage = photoNote }
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
        let shown = content.map(\.plainText).joined()
        write(page: day.pageID, itemID: item.id, message: "Edited: \(shown.prefix(60))",
              showing: PrioritySave(change: .saving, text: shown, isDone: item.isDone)) { document in
            document.replacingTaskItems { current, node in
                current.id == item.id ? ADFNode(type: node.type, attrs: node.attrs, content: content) : node
            }
        }
    }

    func remove(_ item: PriorityItem, from day: PriorityDay) {
        remove(item, from: day, showing: PrioritySave(change: .deleting, text: item.plainText, isDone: item.isDone))
    }

    /// Takes its photos off the page with it. Their files stay attached to
    /// the page, as deleting an image in Confluence's editor leaves them.
    @discardableResult
    private func remove(_ item: PriorityItem, from day: PriorityDay, showing save: PrioritySave?) -> Task<Bool, Never>? {
        write(page: day.pageID, itemID: item.id, message: "Removed: \(item.plainText.prefix(60))", showing: save) { document in
            document.removingPhotos(ofItem: item.id).replacingTaskItems { current, node in current.id == item.id ? nil : node }
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
        let content = ADFNode.inlineContent(from: trimmed, siteURL: siteURL)
        let shown = content.map(\.plainText).joined()
        let item = ADFNode.taskItem(content, id: id)
        write(page: day.pageID, itemID: id, message: "Added: \(shown.prefix(60))",
              showing: PrioritySave(change: .adding, text: shown, isDone: false)) { document in
            itemID.flatMap { document.insertingTaskItem(item, after: $0) } ?? document.appendingTaskItem([item])
        }
        return id
    }

    /// Moves an item from an earlier day onto today's page, when today has
    /// one. Not one with comments, which can't move with it. Its photos'
    /// files are attached to today's page too, so they show there.
    func moveToToday(_ item: PriorityItem, from day: PriorityDay) async {
        guard let today = todayRef, today.pageID != day.pageID, !hasComments(item, in: day) else { return }
        // One change on screen across both pages' saves, so the screen stays
        // locked in between.
        let moveID = UUID()
        saveQueue.append((moveID, PrioritySave(change: .moving, text: item.plainText, isDone: item.isDone)))
        defer { saveQueue.removeAll { $0.id == moveID } }
        var photoBlocks: [ADFNode] = []
        for photo in (pages[day.pageID] ?? day).photos[item.id] ?? [] {
            do {
                photoBlocks.append(try await copy(photo, fromPage: day.pageID, toPage: today.pageID))
            } catch {
                errorMessage = "Couldn't move “\(item.plainText.prefix(60))” to today: its photo didn't copy. \(error.localizedDescription)"
                return
            }
        }
        let moved = ADFNode.taskItem(item.contentWithoutComments, done: item.isDone, id: item.id)
        let added = write(page: today.pageID, itemID: item.id, message: "Moved from \(day.title): \(item.plainText.prefix(50))", showing: nil) { document in
            let added = document.appendingTaskItem([moved])
            return photoBlocks.isEmpty ? added : added.insertingPhotos(photoBlocks, underItem: item.id) ?? added
        }
        // Only off its own day once it's on today's, so a failed save can't lose it.
        guard await added?.value == true else { return }
        _ = await remove(item, from: day, showing: nil)?.value
    }

    // MARK: - Photos

    /// Attaches images to an item's page and puts them under the item, each
    /// shown from the picked image while it uploads. HEIC and the like go
    /// up as JPEG, so every browser shows them. Images that can't be read
    /// are left out, with a note.
    /// `skipped` counts what was picked but couldn't be read as an image.
    func addPhotos(_ images: [(data: Data, filename: String)], skipped: Int = 0, to item: PriorityItem, in day: PriorityDay) async {
        guard client != nil, !images.isEmpty || skipped > 0 else { return }
        guard (pages[day.pageID] ?? day).document.canAddPhotos(toItem: item.id) else {
            errorMessage = PriorityPhotoError.cantAdd.localizedDescription
            return
        }
        var prepared: [(photo: PreparedPhoto, uploadID: UUID)] = []
        var unreadable = skipped
        for image in images {
            guard let photo = await PhotoImaging.prepare(image.data, filename: image.filename) else {
                unreadable += 1
                continue
            }
            let upload = PriorityPhotoUpload(id: UUID(), filename: photo.filename, preview: photo.preview,
                                             pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight)
            photoUploads[item.id, default: []].append(upload)
            prepared.append((photo, upload.id))
        }
        let uploadIDs = Set(prepared.map(\.uploadID))
        func clearUploads() {
            photoUploads[item.id]?.removeAll { uploadIDs.contains($0.id) }
            if photoUploads[item.id]?.isEmpty == true { photoUploads[item.id] = nil }
        }

        var blocks: [ADFNode] = []
        var failure: Error?
        for entry in prepared {
            do {
                blocks.append(try await upload(entry.photo, toPage: day.pageID))
            } catch {
                failure = error
                break
            }
        }
        var note: String?
        if let failure {
            note = "Couldn't attach the photo to the page: \(failure.localizedDescription)"
        } else if unreadable > 0 {
            note = switch (unreadable, blocks.count) {
            case (1, 0): "That isn't an image the app can read."
            case (_, 0): "Those aren't images the app can read."
            case (1, _): "One of those isn't an image the app can read, so it was left out."
            default: "\(unreadable) of those aren't images the app can read, so they were left out."
            }
        }

        if !blocks.isEmpty {
            // Deleted, or indented, while it uploaded.
            guard pages[day.pageID]?.document.canAddPhotos(toItem: item.id) == true else {
                clearUploads()
                errorMessage = "The photo was attached to the page in Confluence, but the priority changed before it could go under it."
                return
            }
            let label = blocks.count == 1 ? "a photo" : "\(blocks.count) photos"
            let saved = write(page: day.pageID, itemID: item.id, message: "Added \(label): \(item.plainText.prefix(50))",
                              showing: PrioritySave(change: .addingPhoto, text: item.plainText, isDone: item.isDone)) { document in
                document.insertingPhotos(blocks, underItem: item.id) ?? document
            }
            // The page shows them now, so the stand-ins can go.
            clearUploads()
            // A save that works clears the message, so a note waits for it.
            guard await saved?.value == true else { return }
        } else {
            clearUploads()
        }
        if let note { errorMessage = note }
    }

    /// Says why photos couldn't be added, where load and save errors show.
    func reportPhotoProblem(_ message: String) {
        errorMessage = message
    }

    /// Takes a photo off the page. Its file stays attached to the page, as
    /// deleting an image in Confluence's editor leaves it.
    func removePhoto(_ photo: PriorityPhoto, from item: PriorityItem, in day: PriorityDay) {
        write(page: day.pageID, itemID: item.id, message: "Removed a photo: \(item.plainText.prefix(50))",
              showing: PrioritySave(change: .removingPhoto, text: item.plainText, isDone: item.isDone)) { document in
            document.removingPhoto(photo.fileID, ofItem: item.id)
        }
    }

    /// A small copy of a photo, for showing under its priority.
    func preview(of photo: PriorityPhoto, onPage pageID: String, maxPixels: Int) async throws -> PlatformImage {
        guard let client else { throw CancellationError() }
        let attachment = try await attachment(for: photo, onPage: pageID)
        return try await PriorityPhotoStore.shared.preview(for: attachment, using: client, maxPixels: maxPixels)
    }

    /// A photo's file, downloaded, to open in Quick Look.
    func file(of photo: PriorityPhoto, onPage pageID: String) async throws -> URL {
        guard let client else { throw CancellationError() }
        let attachment = try await attachment(for: photo, onPage: pageID)
        return try await PriorityPhotoStore.shared.file(for: attachment, using: client)
    }

    /// The attachment a photo shows: on the page its collection names (one
    /// copied in from another page in Confluence still points there), else
    /// the page it's on. Matched by file id, or failing that by name, which
    /// Confluence's editor writes as the alt text. A page's attachments are
    /// listed once, and again when one isn't among them, as it may be new.
    private func attachment(for photo: PriorityPhoto, onPage pageID: String) async throws -> ConfluenceAttachment {
        let owner = photo.pageID ?? pageID
        func find(_ list: [ConfluenceAttachment]) -> ConfluenceAttachment? {
            list.first { $0.fileId == photo.fileID } ?? photo.filename.flatMap { name in list.first { $0.title == name } }
        }
        if let list = attachmentLists[owner], let found = find(list) { return found }
        guard let found = find(try await listAttachments(owner)) else { throw PriorityPhotoError.notFound }
        return found
    }

    /// Lists a page's attachments, once at a time however many photos ask.
    private func listAttachments(_ pageID: String) async throws -> [ConfluenceAttachment] {
        guard let client else { throw CancellationError() }
        if let load = attachmentLoads[pageID] { return try await load.value }
        let load = Task { try await client.confluenceAttachments(pageID: pageID) }
        attachmentLoads[pageID] = load
        defer { attachmentLoads[pageID] = nil }
        let list = try await load.value
        attachmentLists[pageID] = list
        return list
    }

    /// Attaches a prepared photo to a page and returns the image block that
    /// shows it. Its bytes are kept, so it shows without downloading.
    private func upload(_ photo: PreparedPhoto, toPage pageID: String) async throws -> ADFNode {
        let attachment = try await attach(photo.data, filename: photo.filename, mimeType: photo.mimeType, toPage: pageID)
        guard let fileID = attachment.fileId else { throw JiraError.invalidResponse }
        return PriorityPhoto.block(fileID: fileID, pageID: pageID, filename: attachment.title,
                                   pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight)
    }

    /// Attaches a photo's file to another page too, and returns the image
    /// block showing it there as it showed on its own page.
    private func copy(_ photo: PriorityPhoto, fromPage sourceID: String, toPage pageID: String) async throws -> ADFNode {
        guard let client else { throw CancellationError() }
        let source = try await attachment(for: photo, onPage: sourceID)
        let file = try await PriorityPhotoStore.shared.file(for: source, using: client)
        let data = try Data(contentsOf: file)
        let attachment = try await attach(data, filename: source.title, mimeType: source.mediaType ?? "application/octet-stream", toPage: pageID)
        guard let fileID = attachment.fileId else { throw JiraError.invalidResponse }
        var width = photo.pixelWidth
        var height = photo.pixelHeight
        if width == nil || height == nil, let prepared = await PhotoImaging.prepare(data, filename: source.title) {
            width = prepared.pixelWidth
            height = prepared.pixelHeight
        }
        return PriorityPhoto.block(fileID: fileID, pageID: pageID, filename: attachment.title,
                                   pixelWidth: width ?? 1, pixelHeight: height ?? 1, shownWidth: photo.displayWidth)
    }

    /// Attaches a file to a page under a name the page doesn't have yet
    /// ("photo 2.jpg" after "photo.jpg"), since Confluence refuses a second
    /// file by the same name, and notes it among the page's attachments.
    private func attach(_ data: Data, filename: String, mimeType: String, toPage pageID: String) async throws -> ConfluenceAttachment {
        guard let client else { throw CancellationError() }
        var taken = Set((try? await listAttachments(pageID))?.map(\.title) ?? [])
        var name = Self.freeName(filename, taken: taken)
        let attachment: ConfluenceAttachment
        do {
            attachment = try await client.attachToConfluencePage(data, filename: name, mimeType: mimeType, pageID: pageID)
        } catch JiraError.http(400, _) {
            // Someone attached one by that name since the list was read.
            taken.insert(name)
            name = Self.freeName(filename, taken: taken.union((try? await listAttachments(pageID))?.map(\.title) ?? []))
            attachment = try await client.attachToConfluencePage(data, filename: name, mimeType: mimeType, pageID: pageID)
        }
        attachmentLists[pageID, default: []].append(attachment)
        await PriorityPhotoStore.shared.keep(data, for: attachment, site: client.credentials.siteHost)
        return attachment
    }

    /// `name` when it isn't taken, or else it numbered: "photo 2.jpg", "photo 3.jpg", …
    static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 2... {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
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

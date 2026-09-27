import Foundation
import Observation

/// One issue as stored in the local title index.
nonisolated struct IndexedIssue: Codable, Hashable, Sendable {
    let key: String
    let summary: String
    let statusName: String
    let statusCategory: String
    let typeName: String
    let updated: Date

    var projectKey: String { String(key.split(separator: "-").first ?? "") }

    init(_ summary: IssueSummary) {
        key = summary.key
        self.summary = summary.fields.summary
        statusName = summary.fields.status.name
        statusCategory = summary.fields.status.statusCategory?.key ?? "new"
        typeName = summary.fields.issueType.name
        updated = summary.fields.updated
    }
}

/// Local index of issue titles for typo-tolerant search. Built once per
/// account (in parallel date windows), saved to disk, then kept current with
/// small "updated since" refreshes.
@Observable
final class SearchIndex {
    enum Status: Equatable {
        case idle
        case building(done: Int, total: Int?)
        case ready
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var entries: [IndexedIssue] = []
    /// Pre-split title words, parallel to `entries`.
    private(set) var titleWords: [[String]] = []
    /// Bumped whenever the entries change, so searches can re-run.
    private(set) var revision = 0
    private(set) var syncedAt: Date?

    private var prepareTask: Task<Void, Never>?
    private var builtAt: Date?

    private static let fields = ["summary", "status", "issuetype", "updated"]
    private static let windowDays = 60
    private static let parallelWindows = 6
    private static let fullRebuildAge: TimeInterval = 7 * 24 * 3600
    private static let refreshAge: TimeInterval = 120

    var count: Int { entries.count }

    /// Loads the saved index and brings it up to date. Safe to call often:
    /// concurrent callers share one run, and it keeps going even if the
    /// screen that asked goes away.
    func prepare(client: JiraClient, accountID: UUID) async {
        if let prepareTask {
            await prepareTask.value
            return
        }
        let task = Task { await self.run(client: client, accountID: accountID) }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    private func run(client: JiraClient, accountID: UUID) async {

        if entries.isEmpty, let saved = await Self.load(accountID: accountID) {
            apply(saved.issues)
            builtAt = saved.builtAt
            syncedAt = saved.syncedAt
            status = .ready
        }

        do {
            if entries.isEmpty || (builtAt.map { Date.now.timeIntervalSince($0) > Self.fullRebuildAge } ?? true) {
                try await fullBuild(client: client)
            } else if Date.now.timeIntervalSince(syncedAt ?? .distantPast) > Self.refreshAge {
                try await refresh(client: client)
            }
            status = .ready
            await Self.save(IndexFile(builtAt: builtAt ?? .now, syncedAt: syncedAt ?? .now, issues: entries), accountID: accountID)
        } catch {
            status = entries.isEmpty ? .failed(error.localizedDescription) : .ready
        }
    }

    // MARK: - Building

    private func fullBuild(client: JiraClient) async throws {
        let started = Date.now
        let total = try? await client.approximateCount(jql: "created is not EMPTY")
        status = .building(done: 0, total: total)

        guard let earliest = try await client.earliestCreated() else {
            apply([])
            builtAt = started
            syncedAt = started
            return
        }

        // Contiguous created-date windows, fetched a few at a time.
        let calendar = Calendar(identifier: .gregorian)
        var windows: [(Date, Date)] = []
        var start = calendar.startOfDay(for: earliest)
        let end = calendar.date(byAdding: .day, value: 2, to: .now)!
        while start < end {
            let next = calendar.date(byAdding: .day, value: Self.windowDays, to: start)!
            windows.append((start, next))
            start = next
        }

        var collected: [String: IndexedIssue] = [:]
        var done = 0
        try await withThrowingTaskGroup(of: [IndexedIssue].self) { group in
            var nextWindow = 0
            func addNext() {
                guard nextWindow < windows.count else { return }
                let (from, to) = windows[nextWindow]
                nextWindow += 1
                let jql = "created >= \"\(Self.day(from))\" AND created < \"\(Self.day(to))\" ORDER BY key ASC"
                group.addTask { try await Self.fetchAll(jql: jql, client: client) }
            }
            for _ in 0..<Self.parallelWindows { addNext() }
            // On a first build, make titles searchable as they arrive.
            let showPartial = entries.isEmpty
            while let batch = try await group.next() {
                for issue in batch { collected[issue.key] = issue }
                if showPartial {
                    entries += batch
                    titleWords += batch.map { FuzzyMatcher.words($0.summary) }
                }
                done += batch.count
                status = .building(done: done, total: total)
                addNext()
            }
        }

        apply(Array(collected.values))
        builtAt = started
        syncedAt = started
    }

    /// Pulls issues changed since the last sync (with a day of overlap for time zones).
    private func refresh(client: JiraClient) async throws {
        let started = Date.now
        let since = (syncedAt ?? .distantPast).addingTimeInterval(-24 * 3600)
        let changed = try await Self.fetchAll(jql: "updated >= \"\(Self.minute(since))\" ORDER BY updated DESC", client: client)
        if !changed.isEmpty {
            var byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
            for issue in changed { byKey[issue.key] = issue }
            apply(Array(byKey.values))
        }
        syncedAt = started
    }

    private func apply(_ issues: [IndexedIssue]) {
        entries = issues.sorted { $0.updated > $1.updated }
        titleWords = entries.map { FuzzyMatcher.words($0.summary) }
        revision += 1
    }

    private static func fetchAll(jql: String, client: JiraClient) async throws -> [IndexedIssue] {
        var issues: [IndexedIssue] = []
        var token: String?
        repeat {
            let page: SearchPage<IssueSummary> = try await client.search(jql: jql, fields: fields, maxResults: 100, nextPageToken: token)
            issues += page.issues.map(IndexedIssue.init)
            token = page.isLast == true ? nil : page.nextPageToken
        } while token != nil
        return issues
    }

    // MARK: - Persistence

    nonisolated struct IndexFile: Codable, Sendable {
        var version = 1
        let builtAt: Date
        let syncedAt: Date
        let issues: [IndexedIssue]
    }

    private static func fileURL(accountID: UUID) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appending(path: "JPlus", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "search-index-\(accountID.uuidString).json")
    }

    private static func load(accountID: UUID) async -> IndexFile? {
        guard let url = fileURL(accountID: accountID) else { return nil }
        return await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(IndexFile.self, from: data)
        }.value
    }

    private static func save(_ file: IndexFile, accountID: UUID) async {
        guard let url = fileURL(accountID: accountID) else { return }
        await Task.detached {
            if let data = try? JSONEncoder().encode(file) {
                try? data.write(to: url, options: .atomic)
            }
        }.value
    }

    static func delete(accountID: UUID) {
        if let url = fileURL(accountID: accountID) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - JQL dates

    nonisolated private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated private static func minute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

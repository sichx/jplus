import Foundation
import Observation

/// One issue row in the palette. Built from search results or the title cache.
struct PaletteIssue: Hashable, Sendable {
    let key: String
    let summary: String?
    let status: JiraIssue.Status?
    let typeName: String?
    let assignee: String?
    let updated: Date?

    init(key: String, summary: String?, status: JiraIssue.Status? = nil, typeName: String? = nil, assignee: String? = nil, updated: Date? = nil) {
        self.key = key
        self.summary = summary
        self.status = status
        self.typeName = typeName
        self.assignee = assignee
        self.updated = updated
    }

    init(_ summary: IssueSummary) {
        self.init(
            key: summary.key,
            summary: summary.fields.summary,
            status: summary.fields.status,
            typeName: summary.fields.issueType.name,
            assignee: summary.fields.assignee?.displayName,
            updated: summary.fields.updated
        )
    }
}

enum PaletteItem: Identifiable, Hashable {
    case issue(PaletteIssue)
    case version(VersionRoute)

    var id: String {
        switch self {
        case .issue(let issue): return "issue:\(issue.key)"
        case .version(let route): return "version:\(route.version.id)"
        }
    }
}

struct PaletteSection: Identifiable {
    let title: String
    let items: [PaletteItem]
    var id: String { title }
}

/// State and search logic behind the ⌘K palette. One instance per signed-in
/// account, kept between openings so versions load only once.
@Observable
final class CommandPaletteModel {
    var query = ""

    private(set) var recentIssues: [PaletteIssue] = []
    private(set) var issueResults: [PaletteIssue] = []
    private(set) var versionResults: [VersionRoute] = []
    private(set) var isSearching = false
    private(set) var searchError: String?

    private var projects: [JiraProject] = []
    private var versionRoutes: [VersionRoute] = []
    private var versionsProjectKey: String?
    private var generation = 0

    private static let issueLimit = 8
    private static let versionLimit = 6

    var sections: [PaletteSection] {
        var sections: [PaletteSection] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if !recentIssues.isEmpty {
                sections.append(PaletteSection(title: "Recent Issues", items: recentIssues.map(PaletteItem.issue)))
            }
            if !versionResults.isEmpty {
                sections.append(PaletteSection(title: "Unreleased Versions", items: versionResults.map(PaletteItem.version)))
            }
        } else {
            let issues = PaletteSection(title: "Issues", items: issueResults.map(PaletteItem.issue))
            let versions = PaletteSection(title: "Versions", items: versionResults.map(PaletteItem.version))
            // "v1.17" means a version; "5636" or words mean an issue.
            let versionFirst = versionResults.contains {
                $0.version.name.lowercased().hasPrefix(trimmed.lowercased())
            }
            for section in versionFirst ? [versions, issues] : [issues, versions] where !section.items.isEmpty {
                sections.append(section)
            }
        }
        return sections
    }

    var items: [PaletteItem] { sections.flatMap(\.items) }

    /// Called each time the palette opens.
    func prepare(recentKeys: [String], titles: [String: String], projectKey: String?, client: JiraClient) async {
        query = ""
        issueResults = []
        searchError = nil
        let keys = Array(recentKeys.prefix(7))
        recentIssues = keys.map { PaletteIssue(key: $0, summary: titles[$0]) }
        async let details: [IssueSummary] = Self.details(for: keys, client: client)
        await loadVersions(projectKey: projectKey, client: client)
        versionResults = Array(versionRoutes.filter { !$0.version.released && !$0.version.archived }.prefix(Self.versionLimit))

        // Fill in titles, status and type for the recents, keeping their order.
        let found = Dictionary((await details).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        if !found.isEmpty {
            recentIssues = keys.map { key in found[key].map(PaletteIssue.init) ?? PaletteIssue(key: key, summary: titles[key]) }
        }
    }

    /// Latest summaries for the recent keys that were saved at load time.
    func recentTitles() -> [String: String] {
        var titles: [String: String] = [:]
        for issue in recentIssues { if let summary = issue.summary { titles[issue.key] = summary } }
        return titles
    }

    /// Runs for the current query. Call after a short debounce.
    func search(defaultProjectKey: String?, client: JiraClient) async -> [PaletteIssue] {
        generation += 1
        let myGeneration = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            issueResults = []
            versionResults = Array(versionRoutes.filter { !$0.version.released && !$0.version.archived }.prefix(Self.versionLimit))
            isSearching = false
            searchError = nil
            return []
        }

        // Versions filter locally and instantly.
        versionResults = Array(versionRoutes
            .filter { $0.version.name.localizedCaseInsensitiveContains(text) }
            .sorted { lhs, rhs in
                // Unreleased first, then newest by release date.
                if lhs.version.released != rhs.version.released { return !lhs.version.released }
                return (lhs.version.releaseDay ?? .distantPast) > (rhs.version.releaseDay ?? .distantPast)
            }
            .prefix(Self.versionLimit))

        isSearching = true
        searchError = nil
        defer { if myGeneration == generation { isSearching = false } }

        // An exact key ("vpe-5636", or "5636" in the current project) goes first.
        var exactKey = IssueKey.parse(text)
        if exactKey == nil, let project = defaultProjectKey, text.allSatisfy(\.isNumber) {
            exactKey = "\(project.uppercased())-\(text)"
        }

        async let exactMatch: [IssueSummary] = Self.lookup(key: exactKey, client: client)
        async let textMatches: Result<[IssueSummary], Error> = Self.textSearch(text, isKey: IssueKey.parse(text) != nil, client: client)
        let (exact, found) = await (exactMatch, textMatches)

        guard myGeneration == generation else { return [] }

        var seen = Set<String>()
        var combined: [PaletteIssue] = []
        for summary in exact where seen.insert(summary.key).inserted {
            combined.append(PaletteIssue(summary))
        }
        switch found {
        case .success(let summaries):
            for summary in summaries where seen.insert(summary.key).inserted {
                combined.append(PaletteIssue(summary))
            }
        case .failure(let error):
            if combined.isEmpty { searchError = error.localizedDescription }
        }
        issueResults = Array(combined.prefix(Self.issueLimit))
        return issueResults
    }

    // MARK: - Private

    private func loadVersions(projectKey: String?, client: JiraClient) async {
        do {
            if projects.isEmpty { projects = try await client.projects() }
            guard let project = projects.first(where: { $0.key == projectKey }) ?? projects.first else { return }
            if versionsProjectKey == project.key, !versionRoutes.isEmpty { return }
            let versions = try await client.versions(projectKey: project.key)
            versionRoutes = versions
                .filter { !$0.archived }
                .map { VersionRoute(version: $0, project: project) }
            versionsProjectKey = project.key
        } catch {
            // Versions are a convenience here; issues still work without them.
        }
    }

    /// One request for all keys; if any key no longer exists Jira rejects the
    /// whole query, so fall back to looking them up one by one.
    private static func details(for keys: [String], client: JiraClient) async -> [IssueSummary] {
        guard !keys.isEmpty else { return [] }
        let list = keys.map { "\"\($0)\"" }.joined(separator: ", ")
        if let page = try? await client.search(jql: "key in (\(list))", maxResults: keys.count) {
            return page.issues
        }
        return await withTaskGroup(of: [IssueSummary].self) { group in
            for key in keys { group.addTask { await lookup(key: key, client: client) } }
            var all: [IssueSummary] = []
            for await found in group { all += found }
            return all
        }
    }

    private static func lookup(key: String?, client: JiraClient) async -> [IssueSummary] {
        guard let key else { return [] }
        // A key that doesn't exist makes Jira reject the JQL; that just means no match.
        return (try? await client.search(jql: "key = \"\(key)\"", maxResults: 1).issues) ?? []
    }

    private static func textSearch(_ text: String, isKey: Bool, client: JiraClient) async -> Result<[IssueSummary], Error> {
        // A full key needs no text search.
        if isKey { return .success([]) }
        let cleaned = sanitize(text)
        guard cleaned.count >= 2 else { return .success([]) }
        do {
            let page = try await client.search(jql: "text ~ \"\(cleaned)*\" ORDER BY updated DESC", maxResults: issueLimit)
            return .success(page.issues)
        } catch {
            return .failure(error)
        }
    }

    /// Drops characters that Jira's text search treats as operators.
    private static func sanitize(_ text: String) -> String {
        let operators = CharacterSet(charactersIn: "+-&|!(){}[]^~*?:\\\"/'")
        let cleaned = text.unicodeScalars.map { operators.contains($0) ? " " : Character($0) }
        return String(cleaned)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Issue titles remembered per account, so recents can show them offline.
enum IssueTitleCache {
    private static let key = "issueTitles"
    private static let limit = 300

    static func all(in defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ titles: [String: String], in defaults: UserDefaults) {
        guard !titles.isEmpty else { return }
        var merged = all(in: defaults)
        merged.merge(titles) { _, new in new }
        if merged.count > limit {
            // Order is unknown in a dictionary; keep the ones just saved plus an arbitrary remainder.
            let keep = Set(titles.keys)
            let others = merged.keys.filter { !keep.contains($0) }.prefix(limit - keep.count)
            merged = merged.filter { keep.contains($0.key) || others.contains($0.key) }
        }
        defaults.set(merged, forKey: key)
    }
}

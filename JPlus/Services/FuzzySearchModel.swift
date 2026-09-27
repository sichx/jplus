import Foundation
import Observation

/// One ranked result on the search page.
struct SearchHit: Identifiable, Hashable, Sendable {
    let key: String
    var summary: String
    var statusName: String
    var statusCategory: String
    var typeName: String
    var assignee: String?
    var updated: Date
    var score: Double
    /// Normalized title words that matched, for bolding.
    var matchedTitleWords: Set<String>
    /// Found by Jira's word search (so the text or comments matched).
    var textMatch: Bool

    var id: String { key }
    var projectKey: String { String(key.split(separator: "-").first ?? "") }
    var status: JiraIssue.Status {
        JiraIssue.Status(name: statusName, statusCategory: JiraIssue.StatusCategory(key: statusCategory, colorName: nil))
    }
}

/// Filters chosen above the results.
struct SearchFilters: Hashable, Sendable {
    /// nil means all projects.
    var projectKey: String?
    var openOnly: Bool
}

/// Google-style search: local typo-tolerant title matching blended with
/// Jira's word search over descriptions and comments, ranked in the app.
@Observable
final class FuzzySearchModel {
    private(set) var hits: [SearchHit] = []
    private(set) var queryTokens: [String] = []
    private(set) var isSearching = false
    private(set) var elapsed: TimeInterval?
    private(set) var didYouMean: String?
    private(set) var errorMessage: String?
    private(set) var shownCount = FuzzySearchModel.pageSize
    /// Plain-text descriptions for snippets, fetched for visible results.
    private(set) var descriptions: [String: String] = [:]
    /// The query the current results belong to, once its search has finished.
    private(set) var searchedQuery: String?

    static let pageSize = 20
    private var generation = 0

    var visibleHits: ArraySlice<SearchHit> { hits.prefix(shownCount) }
    var canShowMore: Bool { hits.count > shownCount }

    func clear() {
        generation += 1
        searchedQuery = nil
        hits = []
        queryTokens = []
        didYouMean = nil
        errorMessage = nil
        elapsed = nil
        isSearching = false
        shownCount = Self.pageSize
    }

    func search(_ query: String, filters: SearchFilters, index: SearchIndex, preferredProject: String?, client: JiraClient) async {
        generation += 1
        let myGeneration = generation
        let started = Date.now
        let tokens = FuzzyMatcher.queryTokens(query)
        guard !tokens.isEmpty else { clear(); return }

        queryTokens = tokens
        shownCount = Self.pageSize
        errorMessage = nil
        isSearching = true
        defer { if myGeneration == generation { isSearching = false } }

        // 1. Local fuzzy title matches: instant, typo-tolerant.
        let entries = index.entries
        let words = index.titleWords
        let local = await Task.detached(priority: .userInitiated) {
            Self.rankLocal(tokens: tokens, entries: entries, titleWords: words, filters: filters)
        }.value
        guard myGeneration == generation else { return }

        var byKey: [String: SearchHit] = [:]
        var corrections: [String: String] = [:]
        for (issue, match) in local {
            byKey[issue.key] = SearchHit(
                key: issue.key, summary: issue.summary, statusName: issue.statusName,
                statusCategory: issue.statusCategory, typeName: issue.typeName, assignee: nil,
                updated: issue.updated, score: 0, matchedTitleWords: match.matchedWords, textMatch: false
            )
            if byKey.count <= 3 { corrections.merge(match.corrections) { first, _ in first } }
        }
        publish(byKey, query: query, preferredProject: preferredProject, started: started)

        // 2. Jira's word search (descriptions, comments) plus an exact key.
        async let textHits = Self.textSearch(tokens: tokens, filters: filters, client: client)
        async let keyHit = Self.keyLookup(query, preferredProject: preferredProject, client: client)
        let (found, exact) = await (textHits, keyHit)
        guard myGeneration == generation else { return }

        switch found {
        case .success(let details):
            for detail in details { merge(detail, into: &byKey, textMatch: true, tokens: tokens) }
        case .failure(let error):
            if byKey.isEmpty { errorMessage = error.localizedDescription }
        }
        if let exact { merge(exact, into: &byKey, textMatch: false, tokens: tokens) }

        // "Did you mean" when Jira's exact words found nothing but typos did.
        let jiraFoundWords = (try? found.get().isEmpty == false) ?? false
        if !jiraFoundWords, !corrections.isEmpty {
            let fixed = tokens.map { corrections[$0] ?? $0 }
            didYouMean = fixed != tokens ? fixed.joined(separator: " ") : nil
        } else {
            didYouMean = nil
        }

        publish(byKey, query: query, preferredProject: preferredProject, started: started, exactKey: exact?.key)
        searchedQuery = query
        await loadDescriptions(client: client, generation: myGeneration)
    }

    func showMore(client: JiraClient) async {
        shownCount += Self.pageSize
        await loadDescriptions(client: client, generation: generation)
    }

    // MARK: - Ranking

    private func publish(_ byKey: [String: SearchHit], query: String, preferredProject: String?, started: Date, exactKey: String? = nil) {
        let phrase = FuzzyMatcher.words(query).joined(separator: " ")
        let now = Date.now
        var ranked = Array(byKey.values)
        for index in ranked.indices {
            var hit = ranked[index]
            let titleMatch = hit.matchedTitleWords.isEmpty
                ? 0
                : (FuzzyMatcher.match(queryTokens, titleWords: FuzzyMatcher.words(hit.summary))?.score ?? 0)
            var score = titleMatch * 10
            if !phrase.isEmpty, FuzzyMatcher.words(hit.summary).joined(separator: " ").contains(phrase) { score += 3 }
            if hit.textMatch { score += 2.5 }
            if hit.key == exactKey { score += 100 }
            let days = max(0, now.timeIntervalSince(hit.updated) / 86_400)
            score += 1.5 * exp(-days / 120)
            if hit.statusCategory != "done" { score += 0.5 }
            if hit.projectKey == preferredProject { score += 0.5 }
            hit.score = score
            ranked[index] = hit
        }
        hits = ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.updated > $1.updated }
        elapsed = Date.now.timeIntervalSince(started)
    }

    private func merge(_ detail: IssueSearchDetail, into byKey: inout [String: SearchHit], textMatch: Bool, tokens: [String]) {
        let fields = detail.fields
        if let text = fields.description?.plainText { descriptions[detail.key] = Self.collapse(text) }
        if var existing = byKey[detail.key] {
            existing.assignee = fields.assignee?.displayName
            existing.textMatch = existing.textMatch || textMatch
            existing.statusName = fields.status.name
            existing.statusCategory = fields.status.statusCategory?.key ?? existing.statusCategory
            byKey[detail.key] = existing
        } else {
            let titleWords = FuzzyMatcher.words(fields.summary)
            let matched = FuzzyMatcher.match(tokens, titleWords: titleWords)?.matchedWords ?? []
            byKey[detail.key] = SearchHit(
                key: detail.key, summary: fields.summary, statusName: fields.status.name,
                statusCategory: fields.status.statusCategory?.key ?? "new", typeName: fields.issueType.name,
                assignee: fields.assignee?.displayName, updated: fields.updated, score: 0,
                matchedTitleWords: matched, textMatch: textMatch
            )
        }
    }

    nonisolated private static func rankLocal(tokens: [String], entries: [IndexedIssue], titleWords: [[String]], filters: SearchFilters) -> [(IndexedIssue, FuzzyMatcher.TitleMatch)] {
        var matches: [(IndexedIssue, FuzzyMatcher.TitleMatch)] = []
        for (index, issue) in entries.enumerated() {
            if let project = filters.projectKey, issue.projectKey != project { continue }
            if filters.openOnly, issue.statusCategory == "done" { continue }
            if let match = FuzzyMatcher.match(tokens, titleWords: titleWords[index]) {
                matches.append((issue, match))
            }
        }
        return Array(matches.sorted { $0.1.score > $1.1.score }.prefix(150))
    }

    // MARK: - Jira requests

    private static func textSearch(tokens: [String], filters: SearchFilters, client: JiraClient) async -> Result<[IssueSearchDetail], Error> {
        let words = tokens.map(sanitize).filter { $0.count >= 2 }
        guard !words.isEmpty else { return .success([]) }
        // Every word, allowing endings: "download* agreement*".
        var clauses = ["text ~ \"\(words.map { $0 + "*" }.joined(separator: " "))\""]
        if let project = filters.projectKey { clauses.insert("project = \"\(project)\"", at: 0) }
        if filters.openOnly { clauses.append("statusCategory != Done") }
        let jql = clauses.joined(separator: " AND ") + " ORDER BY updated DESC"
        do {
            let page: SearchPage<IssueSearchDetail> = try await client.search(jql: jql, fields: IssueSearchDetail.requestedFields, maxResults: 50)
            return .success(page.issues)
        } catch {
            return .failure(error)
        }
    }

    private static func keyLookup(_ query: String, preferredProject: String?, client: JiraClient) async -> IssueSearchDetail? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var key = IssueKey.parse(trimmed)
        if key == nil, let project = preferredProject, !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) {
            key = "\(project)-\(trimmed)"
        }
        guard let key else { return nil }
        let page: SearchPage<IssueSearchDetail>? = try? await client.search(jql: "key = \"\(key)\"", fields: IssueSearchDetail.requestedFields, maxResults: 1)
        return page?.issues.first
    }

    /// Descriptions for visible results that came only from the local index.
    private func loadDescriptions(client: JiraClient, generation: Int) async {
        let missing = visibleHits.map(\.key).filter { descriptions[$0] == nil }
        guard !missing.isEmpty else { return }
        let list = missing.map { "\"\($0)\"" }.joined(separator: ", ")
        guard let page: SearchPage<IssueSearchDetail> = try? await client.search(
            jql: "key in (\(list))", fields: IssueSearchDetail.requestedFields, maxResults: missing.count
        ) else { return }
        guard generation == self.generation else { return }
        for detail in page.issues {
            descriptions[detail.key] = Self.collapse(detail.fields.description?.plainText ?? "")
            if let index = hits.firstIndex(where: { $0.key == detail.key }) {
                hits[index].assignee = detail.fields.assignee?.displayName
            }
        }
    }

    nonisolated private static func sanitize(_ word: String) -> String {
        let operators = CharacterSet(charactersIn: "+-&|!(){}[]^~*?:\\\"/'")
        return String(word.unicodeScalars.filter { !operators.contains($0) }.map(Character.init))
    }

    nonisolated private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Snippets

    /// About two lines of the description around the first matching word.
    func snippet(for hit: SearchHit) -> String? {
        guard let text = descriptions[hit.key], !text.isEmpty else { return nil }
        let limit = 240
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var anchor = 0
        outer: for (index, word) in words.enumerated() {
            let normalized = FuzzyMatcher.words(String(word)).first ?? ""
            for token in queryTokens where FuzzyMatcher.quality(token, normalized) >= 0.6 {
                anchor = index
                break outer
            }
        }
        let start = max(0, anchor - 8)
        var snippet = words[start...].joined(separator: " ")
        let truncated = snippet.count > limit
        if truncated { snippet = String(snippet.prefix(limit)) }
        return (start > 0 ? "… " : "") + snippet + (truncated ? " …" : "")
    }
}

import Foundation
import Observation

/// Drives a paginated JQL result set for a list view.
@Observable
final class IssueQuery {
    private(set) var jql = ""
    private(set) var issues: [IssueSummary] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var hasRun = false

    private var nextPageToken: String?
    private var generation = 0

    /// Replaces the current results with the first page of `jql`. With
    /// `keepingResults`, the current issues stay listed until that page
    /// arrives, so a list can reload in place instead of flashing empty.
    func run(_ jql: String, using client: JiraClient, keepingResults: Bool = false) async {
        generation += 1
        let myGeneration = generation
        self.jql = jql
        if !keepingResults { issues = [] }
        nextPageToken = nil
        hasMore = false
        errorMessage = nil
        hasRun = true
        await fetchPage(generation: myGeneration, replacing: true, using: client)
    }

    func loadMore(using client: JiraClient) async {
        guard hasMore, !isLoading else { return }
        await fetchPage(generation: generation, replacing: false, using: client)
    }

    private func fetchPage(generation: Int, replacing: Bool, using client: JiraClient) async {
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let page = try await client.search(jql: jql, nextPageToken: nextPageToken)
            guard generation == self.generation else { return }
            issues = replacing ? page.issues : issues + page.issues
            nextPageToken = page.nextPageToken
            hasMore = page.nextPageToken != nil && page.isLast != true
        } catch {
            guard generation == self.generation else { return }
            if replacing { issues = [] }
            errorMessage = error.localizedDescription
        }
    }
}

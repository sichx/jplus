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

    /// Replaces the current results with the first page of `jql`.
    func run(_ jql: String, using client: JiraClient) async {
        generation += 1
        let myGeneration = generation
        self.jql = jql
        issues = []
        nextPageToken = nil
        hasMore = false
        errorMessage = nil
        hasRun = true
        await fetchPage(generation: myGeneration, using: client)
    }

    func loadMore(using client: JiraClient) async {
        guard hasMore, !isLoading else { return }
        await fetchPage(generation: generation, using: client)
    }

    private func fetchPage(generation: Int, using client: JiraClient) async {
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let page = try await client.search(jql: jql, nextPageToken: nextPageToken)
            guard generation == self.generation else { return }
            issues += page.issues
            nextPageToken = page.nextPageToken
            hasMore = page.nextPageToken != nil && page.isLast != true
        } catch {
            guard generation == self.generation else { return }
            errorMessage = error.localizedDescription
        }
    }
}

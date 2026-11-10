import SwiftUI

/// Issues in one Jira space (project), most recently updated first.
/// Resolved ones load only with the Load resolved issues setting on.
struct SpaceIssuesView: View {
    let project: JiraProject
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var query = IssueQuery()
    @AppStorage(ResolvedIssues.storageKey, store: .standard) private var loadsResolved = false

    private var jql: String {
        ResolvedIssues.jql("project = \"\(project.key)\"", loadsResolved: loadsResolved, orderBy: "updated DESC")
    }

    var body: some View {
        content
            .navigationTitle(project.name)
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await run() } }
                        .keyboardShortcut("r", modifiers: .command)
                    if let client = session.client {
                        Button("Open in Jira", systemImage: "safari") {
                            openURL(client.browseURL(jql: jql))
                        }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                        .help("Open these issues in Jira (⇧⌘O)")
                    }
                }
            }
            .loadTask { if !query.hasRun { await run() } }
            .onChange(of: loadsResolved) { Task { await run() } }
    }

    @ViewBuilder
    private var content: some View {
        if let message = query.errorMessage {
            ScaledContentUnavailableView {
                Label("Couldn't Load \(project.name)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await run() } }
            }
        } else if (query.isLoading || !query.hasRun) && query.issues.isEmpty {
            ProgressView("Loading \(project.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.hasRun && query.issues.isEmpty {
            ScaledContentUnavailableView(loadsResolved ? "No Issues" : "No Open Issues", systemImage: "checkmark.circle",
                                         description: Text(loadsResolved ? "\(project.name) has no issues yet." : "\(project.name) has no unresolved issues."))
        } else {
            VStack(spacing: 0) {
                IssueListView(issues: query.issues, onOpen: onOpenIssue, statusFilterKey: "space.\(project.key)")
                Divider()
                IssueListFooter(query: query) {
                    Task { if let client = session.client { await query.loadMore(using: client) } }
                }
            }
        }
    }

    private func run() async {
        guard let client = session.client else { return }
        await query.run(jql, using: client)
    }
}

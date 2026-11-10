import SwiftUI

/// Issues assigned to the signed-in user, most recently updated first.
/// Resolved ones load only with the Load resolved issues setting on.
struct MyIssuesView: View {
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var query = IssueQuery()
    @AppStorage(ResolvedIssues.storageKey, store: .standard) private var loadsResolved = false

    private var jql: String {
        ResolvedIssues.jql("assignee = currentUser()", loadsResolved: loadsResolved, orderBy: "updated DESC")
    }

    var body: some View {
        content
            .navigationTitle("My Issues")
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
                Label("Couldn't Load Your Issues", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await run() } }
            }
        } else if (query.isLoading || !query.hasRun) && query.issues.isEmpty {
            ProgressView("Loading your issues…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.hasRun && query.issues.isEmpty {
            ScaledContentUnavailableView("Nothing Assigned", systemImage: "checkmark.circle",
                                         description: Text(loadsResolved ? "You have no issues assigned to you." : "You have no open issues assigned to you."))
        } else {
            VStack(spacing: 0) {
                IssueListView(issues: query.issues, onOpen: onOpenIssue, statusFilterKey: "myIssues")
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

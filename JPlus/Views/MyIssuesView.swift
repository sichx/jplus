import SwiftUI

/// Open issues assigned to the signed-in user, most recently updated first.
struct MyIssuesView: View {
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var query = IssueQuery()

    private static let jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"

    var body: some View {
        content
            .navigationTitle("My Issues")
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await run() } }
                        .keyboardShortcut("r", modifiers: .command)
                    if let client = session.client {
                        Button("Open in Jira", systemImage: "safari") {
                            openURL(client.browseURL(jql: Self.jql))
                        }
                    }
                }
            }
            .task { if !query.hasRun { await run() } }
    }

    @ViewBuilder
    private var content: some View {
        if let message = query.errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Your Issues", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await run() } }
            }
        } else if query.isLoading && query.issues.isEmpty {
            ProgressView("Loading your issues…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.hasRun && query.issues.isEmpty {
            ContentUnavailableView("Nothing Assigned", systemImage: "checkmark.circle",
                                   description: Text("You have no open issues assigned to you."))
        } else {
            VStack(spacing: 0) {
                IssueListView(issues: query.issues, onOpen: onOpenIssue)
                Divider()
                IssueListFooter(query: query) {
                    Task { if let client = session.client { await query.loadMore(using: client) } }
                }
            }
        }
    }

    private func run() async {
        guard let client = session.client else { return }
        await query.run(Self.jql, using: client)
    }
}

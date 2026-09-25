import AppKit
import SwiftUI

/// Table of issues with double-click to open. Shared by search and versions.
struct IssueListView: View {
    let issues: [IssueSummary]
    let onOpen: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var selection: Set<IssueSummary.ID> = []

    var body: some View {
        Table(issues, selection: $selection) {
            TableColumn("") { issue in
                IssueTypeBadge(name: issue.fields.issueType.name, iconOnly: true)
            }
            .width(24)

            TableColumn("Key") { issue in
                Text(issue.key).monospaced()
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("Summary") { issue in
                Text(issue.fields.summary).lineLimit(1).help(issue.fields.summary)
            }

            TableColumn("Status") { issue in
                StatusBadge(status: issue.fields.status)
            }
            .width(min: 90, ideal: 120, max: 180)

            TableColumn("Assignee") { issue in
                PersonCell(user: issue.fields.assignee)
            }
            .width(min: 100, ideal: 150, max: 220)

            TableColumn("Updated") { issue in
                Text(issue.fields.updated, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .help(issue.fields.updated.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 80, ideal: 110, max: 160)
        }
        .contextMenu(forSelectionType: IssueSummary.ID.self) { ids in
            if let key = key(for: ids) {
                Button("Open \(key)") { onOpen(key) }
                if let client = session.client {
                    Button("Open in Jira") { openURL(client.browseURL(for: key)) }
                }
                Button("Copy Key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let key = key(for: ids) { onOpen(key) }
        }
    }

    private func key(for ids: Set<IssueSummary.ID>) -> String? {
        guard let id = ids.first else { return nil }
        return issues.first { $0.id == id }?.key
    }
}

/// Footer under an `IssueListView`: count, load-more, spinner, error.
struct IssueListFooter: View {
    let query: IssueQuery
    let onLoadMore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if query.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            } else {
                Text(query.issues.count == 1 ? "1 issue" : "\(query.issues.count) issues")
                    .foregroundStyle(.secondary)
                if query.hasMore {
                    Button("Load More", action: onLoadMore)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

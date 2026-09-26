import SwiftUI

/// Loads and displays one issue by key.
struct IssueDetailView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    let key: String

    private enum Phase {
        case loading
        case loaded(JiraIssue)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading \(key)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load \(key)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            case .loaded(let issue):
                IssueContentView(issue: issue)
            }
        }
        .navigationTitle(key)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
                .keyboardShortcut("r", modifiers: .command)
                if let client = session.client {
                    Button("Open in Jira", systemImage: "safari") {
                        openURL(client.browseURL(for: key))
                    }
                }
            }
        }
        .task { await load() }
    }

    private var subtitle: String {
        if case .loaded(let issue) = phase { return issue.fields.summary }
        return ""
    }

    private func load() async {
        guard let client = session.client else {
            phase = .failed("Not signed in.")
            return
        }
        phase = .loading
        do {
            phase = .loaded(try await client.issue(key: key))
        } catch JiraError.notFound {
            phase = .failed("No issue with key \(key), or you don't have permission to view it.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Content

private struct IssueContentView: View {
    let issue: JiraIssue

    private var fields: JiraIssue.Fields { issue.fields }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                metadata
                EffortEstimateView(issue: issue)
                    .id(issue.key)
                Divider()
                section("Description") {
                    if let description = fields.description, !description.children.isEmpty {
                        ADFView(node: description)
                    } else {
                        Text("No description").foregroundStyle(.secondary)
                    }
                }
                Divider()
                comments
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let parent = fields.parent {
                    Text(parent.key).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                IssueTypeBadge(name: fields.issueType.name)
                Text(issue.key)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                StatusBadge(status: fields.status)
            }
            Text(fields.summary)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
        }
    }

    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            row("Assignee") { PersonCell(user: fields.assignee) }
            row("Reporter") { PersonCell(user: fields.reporter) }
            if let priority = fields.priority {
                row("Priority") { PriorityLabel(name: priority.name) }
            }
            if !fields.labels.isEmpty {
                row("Labels") { TagList(items: fields.labels) }
            }
            if !fields.components.isEmpty {
                row("Components") { TagList(items: fields.components.map(\.name)) }
            }
            if !fields.fixVersions.isEmpty {
                row("Fix versions") { TagList(items: fields.fixVersions.map(\.name)) }
            }
            if let parent = fields.parent {
                row("Parent") {
                    Text("\(parent.key)  \(parent.fields?.summary ?? "")").textSelection(.enabled)
                }
            }
            row("Created") { Text(fields.created, format: .dateTime) }
            row("Updated") { Text(fields.updated, format: .relative(presentation: .named)) }
        }
        .font(.callout)
    }

    private var comments: some View {
        let list = fields.comment?.comments ?? []
        return section("Comments (\(fields.comment?.total ?? list.count))") {
            if list.isEmpty {
                Text("No comments").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(list) { comment in
                        CommentView(comment: comment)
                    }
                }
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

// MARK: - Pieces

private struct CommentView: View {
    let comment: JiraIssue.Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(user: comment.author, size: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author?.displayName ?? "Unknown").fontWeight(.medium)
                    Text(comment.created, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .help(comment.created.formatted(date: .abbreviated, time: .shortened))
                    if comment.updated.timeIntervalSince(comment.created) > 60 {
                        Text("(edited)").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                if let body = comment.body {
                    ADFView(node: body)
                }
            }
        }
    }
}

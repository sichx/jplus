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
    @AppStorage("showIssueDetailsPane") private var showDetailsPane = true

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
        .inspector(isPresented: $showDetailsPane) {
            Group {
                if case .loaded(let issue) = phase {
                    IssueDetailsPane(issue: issue)
                } else {
                    Color.clear
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDetailsPane.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help(showDetailsPane ? "Hide ticket details (⌥⌘0)" : "Show ticket details (⌥⌘0)")
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
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
            let issue = try await client.issue(key: key)
            phase = .loaded(issue)
            if let id = session.currentAccountID {
                IssueTitleCache.save([issue.key: issue.fields.summary], in: AccountDefaults.store(for: id))
            }
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

// MARK: - Details pane (right-hand column)

/// Ticket fields and the effort estimate, shown in the right-hand column.
private struct IssueDetailsPane: View {
    let issue: JiraIssue

    private var fields: JiraIssue.Fields { issue.fields }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Details").font(.headline)
                    Spacer()
                    StatusBadge(status: fields.status)
                }

                VStack(alignment: .leading, spacing: 14) {
                    field("Assignee") { PersonCell(user: fields.assignee, avatarSize: 20) }
                    field("Reporter") { PersonCell(user: fields.reporter, avatarSize: 20) }
                    field("Type") { IssueTypeBadge(name: fields.issueType.name) }
                    if let priority = fields.priority {
                        field("Priority") { PriorityLabel(name: priority.name) }
                    }
                    if let parent = fields.parent {
                        field("Parent") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parent.key).font(.callout.monospaced())
                                if let summary = parent.fields?.summary {
                                    Text(summary).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                    if !fields.fixVersions.isEmpty {
                        field("Fix versions") { TagList(items: fields.fixVersions.map(\.name)) }
                    }
                    if !fields.components.isEmpty {
                        field("Components") { TagList(items: fields.components.map(\.name)) }
                    }
                    if !fields.labels.isEmpty {
                        field("Labels") { TagList(items: fields.labels) }
                    }
                    field("Created") {
                        Text(fields.created.formatted(date: .abbreviated, time: .shortened))
                    }
                    field("Updated") {
                        Text(fields.updated, format: .relative(presentation: .named))
                            .help(fields.updated.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.callout)

                Divider()

                EffortEstimateView(issue: issue)
                    .id(issue.key)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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

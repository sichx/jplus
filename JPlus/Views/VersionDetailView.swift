import SwiftUI

/// One version: header with dates and progress, then its issues.
struct VersionDetailView: View {
    let route: VersionRoute
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var query = IssueQuery()
    @State private var highlights: VersionHighlights?
    @State private var isLoadingHighlights = false
    @State private var highlightsError: String?

    private var version: JiraVersion { route.version }

    private var jql: String {
        "project = \(route.project.key) AND fixVersion = \(version.id) ORDER BY status ASC, priority DESC, updated DESC"
    }

    var body: some View {
        VSplitView {
            ScrollView {
                header
            }
            .frame(minHeight: 120, idealHeight: 380)
            issues
                .frame(minHeight: 160)
        }
        .navigationTitle(version.name)
        .navigationSubtitle(route.project.name)
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        async let issues: Void = run()
                        async let notes: Void = loadHighlights()
                        _ = await (issues, notes)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                if let client = session.client {
                    Button("Open in Jira", systemImage: "safari") {
                        openURL(client.browseURL(jql: jql))
                    }
                }
            }
        }
        .task { await run() }
        .task { await loadHighlights() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(version.name).font(.title2.weight(.semibold))
                VersionStateBadge(version: version)
            }
            if let description = nonEmpty(version.description) ?? highlights?.description {
                Text(description).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 20) {
                if let start = version.startDay {
                    Label("Start \(start.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                }
                if let release = version.releaseDay {
                    Label("Release \(release.formatted(date: .abbreviated, time: .omitted))", systemImage: "flag.checkered")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let counts = version.issuesStatusForFixVersion, counts.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    VersionProgressBar(counts: counts)
                        .frame(height: 8)
                        .frame(maxWidth: 480)
                    HStack(spacing: 14) {
                        legend(.green, "\(counts.done) done")
                        legend(.blue, "\(counts.inProgress) in progress")
                        legend(.secondary.opacity(0.4), "\(counts.toDo + counts.unmapped) to do")
                        Text("\(Int((counts.doneFraction * 100).rounded()))%")
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            highlightsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var highlightsSection: some View {
        if let highlights, highlights.hasContent, let content = highlights.content {
            Divider().padding(.vertical, 4)
            Text(nonEmpty(highlights.title) ?? "Version highlights")
                .font(.headline)
            ADFView(node: content)
                .frame(maxWidth: 820, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    // Ticket links on this site open in the app; anything else goes to the browser.
                    if url.host() == session.client?.credentials.siteURL.host(),
                       let key = IssueKey.parse(url.absoluteString) {
                        onOpenIssue(key)
                        return .handled
                    }
                    return .systemAction
                })
        } else if isLoadingHighlights {
            Divider().padding(.vertical, 4)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading version highlights…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let highlightsError {
            Divider().padding(.vertical, 4)
            Label(highlightsError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Fetches this version's highlights directly, so the detail never
    /// depends on the list having finished loading them.
    private func loadHighlights() async {
        guard let client = session.client else { return }
        isLoadingHighlights = highlights == nil
        highlightsError = nil
        defer { isLoadingHighlights = false }
        do {
            let cloudId = try await session.cloudId()
            let found = try await client.versionHighlights(projectId: route.project.id, cloudId: cloudId, search: version.name)
            highlights = found[version.id]
        } catch {
            if highlights == nil {
                highlightsError = "Couldn't load version highlights: \(error.localizedDescription)"
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    @ViewBuilder
    private var issues: some View {
        if let message = query.errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Issues", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await run() } }
            }
        } else if query.isLoading && query.issues.isEmpty {
            ProgressView("Loading issues…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.hasRun && query.issues.isEmpty {
            ContentUnavailableView("No Issues", systemImage: "shippingbox",
                                   description: Text("Nothing has this fix version yet."))
        } else {
            VStack(spacing: 0) {
                IssueListView(issues: query.issues, onOpen: onOpenIssue)
                Divider()
                IssueListFooter(query: query) {
                    Task {
                        if let client = session.client { await query.loadMore(using: client) }
                    }
                }
            }
        }
    }

    private func run() async {
        guard let client = session.client else { return }
        await query.run(jql, using: client)
    }
}

import SwiftUI

/// Advanced search: raw JQL with presets, history, and paginated results.
struct JQLSearchView: View {
    let onOpenIssue: (String) -> Void
    let onSimpleSearch: () -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL

    @AppStorage("lastJQL") private var jql = Preset.assignedToMe.jql
    @AppStorage("jqlHistory") private var historyRaw = ""
    @State private var query = IssueQuery()
    @FocusState private var fieldFocused: Bool

    private enum Preset: String, CaseIterable, Identifiable {
        case assignedToMe = "Assigned to me"
        case reportedByMe = "Reported by me"
        case recentlyUpdated = "Updated this week"
        case openBugs = "Open bugs"
        case watching = "Watched by me"

        var id: String { rawValue }

        var jql: String {
            switch self {
            case .assignedToMe: return "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"
            case .reportedByMe: return "reporter = currentUser() ORDER BY created DESC"
            case .recentlyUpdated: return "updated >= -7d ORDER BY updated DESC"
            case .openBugs: return "issuetype = Bug AND resolution = Unresolved ORDER BY priority DESC, updated DESC"
            case .watching: return "watcher = currentUser() AND resolution = Unresolved ORDER BY updated DESC"
            }
        }
    }

    private var history: [String] {
        historyRaw.components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Advanced Search")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                if let client = session.client, query.hasRun {
                    Button("Open in Jira", systemImage: "safari") {
                        openURL(client.browseURL(jql: query.jql))
                    }
                }
            }
        }
        .task {
            // An empty saved query would leave the screen blank; start from "assigned to me".
            if jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                jql = Preset.assignedToMe.jql
            }
            if !query.hasRun { await run() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("JQL", text: $jql, prompt: Text("Type a JQL query, or pick a preset from the clock menu"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .focused($fieldFocused)
                .onSubmit { Task { await run() } }

            Menu {
                Section("Presets") {
                    ForEach(Preset.allCases) { preset in
                        Button(preset.rawValue) {
                            jql = preset.jql
                            Task { await run() }
                        }
                    }
                }
                if !history.isEmpty {
                    Section("Recent") {
                        ForEach(history, id: \.self) { item in
                            Button(item) {
                                jql = item
                                Task { await run() }
                            }
                        }
                        Button("Clear Recent") { historyRaw = "" }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Presets and recent queries")

            Button("Search") { Task { await run() } }
                .disabled(jql.trimmingCharacters(in: .whitespaces).isEmpty || query.isLoading)

            Button("Simple Search", action: onSimpleSearch)
                .help("Back to plain-words search")
        }
        .padding(12)
    }

    @ViewBuilder
    private var results: some View {
        if let message = query.errorMessage {
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await run() } }
            }
        } else if query.isLoading && query.issues.isEmpty {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.hasRun && query.issues.isEmpty {
            ContentUnavailableView("No Matching Issues", systemImage: "magnifyingglass",
                                   description: Text("Try a different JQL query."))
        } else {
            VStack(spacing: 0) {
                IssueListView(issues: query.issues, onOpen: onOpenIssue)
                Divider()
                IssueListFooter(query: query) {
                    Task { await loadMore() }
                }
            }
        }
    }

    private func run() async {
        guard let client = session.client else { return }
        let trimmed = jql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remember(trimmed)
        await query.run(trimmed, using: client)
    }

    private func loadMore() async {
        guard let client = session.client else { return }
        await query.loadMore(using: client)
    }

    private func remember(_ jql: String) {
        var items = history.filter { $0 != jql }
        items.insert(jql, at: 0)
        historyRaw = items.prefix(10).joined(separator: "\u{1F}")
    }
}
